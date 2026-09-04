# The contracts

Four contracts hold the container together: **relay** (how seats hand each other messages),
**digest** (how seats leave one-line claims and read receipts), **dispatch** (how a seat hands
one job to one runner and gets a report file back), and **receipts** (what counts as proof).
This page states each one precisely enough that a re-implementation in another language,
dropped in place of `bin/`, would pass `examples/demo.sh`. The bash files in `bin/` are the
reference implementation; where this page and a tool disagree, the tool is the bug.

Vocabulary (seat, bus, state, out, runners) is in `docs/CONTAINER.md`.

## 0. Conventions shared by every contract

- **Names.** Seats, peers, and job ids match `^[A-Za-z0-9][A-Za-z0-9_.-]*$`. Runner names
  match `^[A-Za-z0-9][A-Za-z0-9_-]*$` (no dot: they become keys in a flattened JSON path).
  A name never encodes a host, an account, or a person.
- **Time.** UTC, second precision, `YYYY-MM-DDTHH:MM:SSZ`. Job ids use the compact form
  `YYYYMMDDTHHMMSSZ`.
- **Append only.** Inboxes, the digest, the receipts file, and the ledger are only ever
  appended to. No tool truncates, sorts, rewrites, or deletes them. Each record is built in
  memory first and written with **one** write call, so a concurrent reader sees either nothing
  or the whole record.
- **Hashes.** SHA-256, lowercase hex. Displayed ids are the first 12 hex characters.
- **Exit codes.** `0` = did what was asked (printed, posted, delivered), `1` = nothing to
  show or the outcome was not OK, `2` = bad usage, bad config, nothing written.
- **Errors are verbatim.** Diagnostics go to stderr, prefixed with the tool name. Nothing is
  swallowed; a runner's stderr is copied into its report when the job did not succeed.
- **Placeholders.** `<bus>`, `<state>`, `<out>` are the roots from `docs/CONTAINER.md`.

## 1. Relay protocol

One append-only inbox per seat: `<bus>/<seat>/inbox.md`, root from `RELAY_ROOT`
(default `./.relay`). A message is a *frame*. Frames are delivered once per reader, tracked
by content hash in a ledger that lives **outside** the bus.

### 1.1 Wire format

```
---
from: <sender>
to: <recipient>
time: <UTC>
subject: <one line>
---
<body: zero or more lines>
===END===
```

- Every line ends with `\n`, including `===END===`.
- Header values are separated from their key by `: `. The reader strips the key and at most
  one following space. Unknown header lines are ignored by the parser but are part of the frame.
- The body is written as given, followed by exactly one `\n`, then the terminator.
- A body line may not *start with* `===END===`. The sender refuses such a body; there is no
  escaping.
- Text between frames (anything before the first `---` or after an `===END===` that is not
  `---`) is ignored by readers. It is not an error.

### 1.2 Sender: `relay-send`

```
relay-send --from <me> --to <peer> --subject "<one line>" [--body "<text>"]
printf 'text\n' | relay-send --from hub --to worker --subject "job 12"
```

Rules, in order:

1. `--from` and `--to` are required names; `--subject` is required, non-empty, one line.
2. Body comes from `--body`, else from stdin when stdin is not a terminal. Empty body is an
   error. A body containing a line that starts with `===END===` is an error.
3. `mkdir -p <bus>/<to>`; build the whole frame; append it with one write.
4. Print `relay-send: <from> -> <inbox path> (<N> bytes)` on stdout; exit `0`.
   All validation failures exit `2` and write nothing.

A sender never reads the inbox and never checks whether the peer exists. A missing inbox
means no mail yet, not an error.

### 1.3 Reader: `relay-read`

```
relay-read --as <me>            print unread frames, then mark them consumed
relay-read --as <me> --peek     print unread frames, mark nothing
relay-read --as <me> --all      print every complete frame, consumed ones tagged; marks unread ones
relay-read --as <me> --count    print the number of unread frames, mark nothing; always exit 0
relay-read --as <me> --json     one JSON object per frame instead of the frame text
```

Parsing is a single pass over the inbox with three states:

| State | On line | Action |
|-------|---------|--------|
| between frames | `---` | start a frame; anything else is skipped |
| in header | `---` | switch to body |
| in header | `key: value` | record `from`, `to`, `time`, `subject`; ignore other keys |
| in body | `===END===` | frame complete: emit, return to *between* |
| in body | anything | append to body |

- **Frame id** = SHA-256 of the raw frame bytes from its opening `---\n` through its
  `===END===\n`, inclusive. Two byte-identical frames have one id and are delivered once.
- **Ledger** = `RELAY_LEDGER`, default `${XDG_STATE_HOME:-~/.local/state}/relay/<me>.seen`,
  one 64-hex id per line, append only. A frame is *unread* iff its id is not in the ledger.
- **Marking** appends the ids of every frame printed and not yet consumed, in one write,
  after printing. `--peek` and `--count` never write the ledger.
- A **partial** trailing frame (no `===END===` yet) is ignored and reported once on stderr:
  `relay-read: 1 incomplete message pending in <inbox> (no ===END=== yet)`.
- The inbox is never opened for writing.

Output, text mode: for each frame, one line `--- id: <12 hex>` (with ` (consumed)` appended
under `--all` when it was already in the ledger), then the raw frame verbatim.

Output, `--json`: one object per line, keys in this order:
`{"id","from","to","time","subject","body","consumed"}` where `body` is the body with its
final `\n` removed and `consumed` is `true`/`false`.

Exit: `0` if at least one frame was printed, `1` if nothing was printed (including no inbox),
`2` on bad usage. `--count` prints an integer (`0` when there is no inbox) and exits `0`.

## 2. Digest contract

The digest is the shared one-line-per-event log: `DIGEST_FILE`, default `./DIGEST.md`. Every
seat on a bus must point at the **same** file (see the bootstrap contract; two tools have
different defaults). Reading it leaves a receipt in `DIGEST_RECEIPTS`, default
`digest-reads.jsonl` next to the digest. Both files are on the bus and append only.

Seat name resolution, for every verb: `--as <seat>`, else `$DIGEST_SEAT`, else `$USER`,
else `anon`.

### 2.1 Line format

```
- <UTC> [<seat>] <text>
```

`digest post [--as <seat>] "<text>"` (or `<text>` on stdin when stdin is not a terminal)
appends exactly one such line. Empty text and text containing a newline exit `2`. Prints
`digest: posted as <seat> -> <file>`, exit `0`.

A line is a *claim*. The convention every seat and human relies on: a line whose text
contains `FAILED` (the dispatch tool writes `FAILED: ` as a prefix) means something needs
acting on. **Silence is not success.** Nothing else about the text is prescribed.

### 2.2 Read with receipt

`digest [-n N] [--as <seat>]` prints the last `N` lines (default 20) and then appends one
receipt:

```
{"time":"<UTC>","seat":"<seat>","lines":<L>,"head":"<12 hex>"}
```

- `lines` = number of lines in the digest at read time (unquoted integer).
- `head` = first 12 hex of SHA-256 of the **last line including its trailing newline**.
- Keys appear in exactly this order with no whitespace. `digest who` parses positionally.
- If any printed line contains `FAILED`, a warning goes to stderr
  (`digest: N line(s) marked FAILED above; silence is not success`). Exit stays `0`.
- `--no-receipt` prints without appending. For humans and monitors, never for a seat that
  is about to act.
- An empty or missing digest prints nothing and exits `1`; no receipt is written.

### 2.3 Who read what

`digest who` reads the receipts, keeps the **last** receipt per seat, compares it with the
digest as it is now (`L` lines, head `H`), and prints one line per seat, sorted by seat:

```
<seat padded 12> <time padded 20> <seen>/<L>  <status>
```

with `status` decided in this order:

| Condition | Status |
|-----------|--------|
| receipt head == `H` | `current` |
| receipt lines < `L` | `<L - lines> behind` |
| otherwise | `stale (digest rewritten since)` |

The third case is the tripwire for a violated append-only rule: a seat has a receipt for a
digest that no longer has that tail. No receipts at all exits `1`.

## 3. Dispatch contract

`dispatch` hands **one** prompt to **one** runner and produces a **report file**. Nothing the
runner prints reaches the caller's terminal. The contract is identical for every runner,
whatever model or command sits behind it.

### 3.1 Runners file

JSON, path from `--runners`, else `DISPATCH_RUNNERS`, else
`<repo>/examples/runners.example.json`.

```json
{
  "defaults": { "timeout_sec": 300, "budget_bytes": 200000, "max_depth": 2 },
  "runners": {
    "<name>": {
      "description": "one line, shown by `dispatch runners`",
      "command": "ONE line of shell, run as `bash -c`",
      "timeout_sec": 900,
      "budget_bytes": 50000
    }
  }
}
```

Resolution for `timeout_sec` and `budget_bytes`: command-line flag, else the runner's field,
else `defaults`, else the built-ins `300` and `200000`. `max_depth` comes from `defaults`,
else `2`. All must be whole numbers; timeout and budget must be `> 0`. Other keys are ignored.

### 3.2 Running a job

```
dispatch [run] --runner <name> [--job <id>] [--timeout <sec>] [--budget <bytes>]
         [--notify <seat>] [--bg] [--no-digest] [--runners <file>]
         ("<prompt>" | --prompt-file <f> | prompt on stdin)
```

1. **Depth check first.** `depth = $DISPATCH_DEPTH` (default `0`). The job would run at
   `depth + 1`; if that exceeds `max_depth`, exit `2` before anything is written. This is the
   floor under agents that dispatch agents.
2. **Job id** = `--job`, else `<YYYYMMDDTHHMMSSZ>-<runner>-<4 hex>`. Must be a name.
   `<out>/<job>/` must not already exist. `out` = `DISPATCH_OUT`, default `./dispatch-out`,
   made absolute.
3. **Files written before the runner starts:** `prompt.md` (the prompt plus `\n`) and the
   report header (3.3).
4. **The runner** is `bash -c "<command>"` with the prompt on stdin and in
   `$DISPATCH_PROMPT_FILE`; stdout captured, stderr to `<job>/stderr.log`, no tty.
   Environment added: `DISPATCH_JOB`, `DISPATCH_JOB_DIR`, `DISPATCH_PROMPT_FILE`,
   `DISPATCH_RUNNER`, `DISPATCH_DEPTH` (= `depth + 1`), `DISPATCH_RUNNERS` and
   `DISPATCH_OUT` (both absolute), so a nested `dispatch` inside the runner inherits the
   tree and the depth.
5. **Deadline.** At `timeout_sec` the runner gets `TERM`; 5 s later, `KILL`.
6. **Budget.** Runner stdout is captured up to `budget_bytes + 1`; the report receives at
   most `budget_bytes` of it, with a `\n` added if the captured output did not end in one.
7. **Status**, decided in this order:

   | Condition | STATUS |
   |-----------|--------|
   | killed by the deadline (exit 124 or 137) | `TIMEOUT` |
   | captured bytes > `budget_bytes` | `OVER_BUDGET` (reported `bytes` = the budget) |
   | exit 0 | `OK` |
   | anything else | `FAILED` |

8. **Footer and sentinel** (3.3), written in one write. Nothing is written to the report
   after the sentinel, by anyone, ever.
9. **`meta.json`**, one object:
   `{"job","runner","command","status","exit","bytes","budget_bytes","timeout_sec","seconds","depth","started","finished","report"}`
   with `report` the absolute path of `report.md`.
10. **Digest line** (unless `--no-digest`), posted as seat `$DISPATCH_SEAT` (default
    `dispatch`) to `DIGEST_FILE` (default `<out>/DIGEST.md` when unset):

    ```
    job <job> <STATUS> runner=<runner> <seconds>s <bytes>B -> <report path>
    ```

    prefixed with `FAILED: ` whenever STATUS is not `OK`.
11. **Notice** (only with `--notify <seat>`): one relay frame from `$DISPATCH_SEAT` to
    `<seat>`, subject `job <job> <STATUS>`, body = `report: <report path>` followed by the
    last 7 lines of the report, which are exactly the footer and the sentinel. The receiver
    learns the outcome from the frame and the location from the path; it never needs a pid.
12. Print the report path on stdout. Exit `0` iff STATUS is `OK`, else `1`.
    Digest or relay failures in steps 10 and 11 are reported on stderr and do not change
    STATUS or the exit code.

`--bg` runs steps 4 to 12 in the background with its stdout and stderr in
`<job>/dispatch.log`, prints the job id, and exits `0` at once.

### 3.3 Report format: `<out>/<job>/report.md`

```
# job <job>
runner: <name>
command: <command line as configured>
depth: <depth + 1>
timeout_sec: <n>
budget_bytes: <n>
started: <UTC>
---
<runner stdout, at most budget_bytes>
--- stderr (last 20 lines)          only when STATUS != OK and stderr.log is non-empty
<tail of stderr.log>
---
status: <STATUS>
exit: <runner exit code>
bytes: <n>
seconds: <n>
finished: <UTC>
===DONE=== <STATUS>
```

The sentinel `===DONE=== <STATUS>` is the **last line of the file**. Its presence means the
job is finished and every other file in the job directory is final. Its absence means
running, however long ago the process died. Wait on the file, not the pid.

### 3.4 Status and listing

```
dispatch status <job> [--wait <sec>]    prints "<job> <STATUS>"; STATUS is RUNNING while the
                                        sentinel is absent; --wait polls once per second
dispatch runners                        one runner per entry: name, description, command
```

`status` reads only the last line of the report. Exit `0` = sentinel present, `1` = still
`RUNNING` after the wait, `2` = no such job directory.

## 4. Receipts: what counts as proof

A claim is anything a seat or a runner says happened. Proof is a file on the bus, written by
the contract, that a **different** process can check without trusting the claimant. The
container recognises exactly these:

| Claim | Proof on disk | Who can check it |
|-------|---------------|------------------|
| a message was sent | the frame in `<bus>/<peer>/inbox.md`, closed by `===END===` | anyone with the bus |
| a message was received | its id in the reader's ledger, and a `--count` of `0` | the reader's machine |
| a job finished, with outcome S | `===DONE=== S` as the last line of its report; `meta.json` | anyone with the out tree |
| an event happened | a dated, attributed digest line | anyone with the bus |
| a seat saw the state | a receipt with that seat, `digest who` says `current` | anyone with the bus |
| the bus is intact | no seat is `stale` in `digest who`; inboxes still hold their old frames | anyone with the bus |

Two consequences the doctrine relies on:

- **Maker is never checker.** The process that wrote a claim does not verify it. The demo's
  worker seat writes; the hub seat checks; the check list is a third block of code that reads
  only files.
- **Absence is a finding.** A seat with no receipt did not read. A report without a sentinel
  is not done. A hand-off with no frame did not happen. None of these are inferred from a
  process table, a log line, or a memory of having done it.

## 5. Conformance

A re-implementation conforms when, with its four tools substituted for `bin/relay-send`,
`bin/relay-read`, `bin/digest`, and `bin/dispatch` (same names, same flags, same files),
`bash examples/demo.sh` exits `0`. The demo asserts, from disk, after both seats have run:

1. the report exists and is not empty
2. its last line is `===DONE=== OK`
3. with the stub runner, the prompt's token appears in the report
4. `meta.json` contains `"status":"OK"`
5. the hub's inbox contains a line `subject: job <job> OK`
6. the hub's unread count is `0` after reading it
7. the worker's inbox still contains `subject: task <job>:` (nothing was rewritten)
8. the digest contains `job <job> OK`
9. the digest contains no line with `FAILED`
10. the receipts contain a read by `worker`
11. the receipts contain a read by `hub`
12. `digest who` reports both `hub` and `worker` as `current`

Anything the demo does not check is still part of the contract; the demo is the floor.
