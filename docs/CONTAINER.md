# The container

The harness is water. The container is the thing.

A *harness* is whatever runs a model today: an agent CLI, a chat tab, a local runtime, a cloud
seat. Harnesses change every few months and none of them remembers anything you did not write
down. A *container* is the small set of files and rules that outlive every harness: a shared
directory, a few append-only files inside it, and the contracts in `docs/CONTRACTS.md` that
say how seats hand work to each other and leave proof. Swap the model and the container does
not notice. That is the whole design.

This page is the roots map (what exists on disk, who writes it, who reads it) and the
bootstrap contract (what a seat may assume when it starts, and what it must never do).

## Vocabulary

- **Seat.** One process acting under one plain name (`hub`, `worker`, `reviewer`). A seat is a
  role, not a model. Names match `[A-Za-z0-9][A-Za-z0-9_.-]*` and never encode an account,
  a hostname, or a person.
- **Bus.** The one directory every seat can read and write. It may be a plain local directory
  or a folder synced between machines. Everything shared lives here and nowhere else.
- **State.** Per-seat, per-machine files that must *not* travel with the bus.
- **Out.** The job tree that `bin/dispatch` writes. One directory per job.
- **Runners.** A JSON file mapping runner names to one-line shell commands. The only place a
  model or CLI is named.

## Roots map

| Root | Env var | Default | Written by | Read by | Travels with the bus? |
|------|---------|---------|------------|---------|-----------------------|
| bus root | `RELAY_ROOT` | `./.relay` | every seat, append only | every seat | yes |
| inbox `<bus>/<seat>/inbox.md` | derived | | `bin/relay-send`, `bin/dispatch --notify` | `bin/relay-read --as <seat>` | yes |
| digest `DIGEST.md` | `DIGEST_FILE` | `./DIGEST.md` | `bin/digest post`, `bin/dispatch` | `bin/digest`, humans | yes |
| receipts `digest-reads.jsonl` | `DIGEST_RECEIPTS` | next to the digest | `bin/digest` on every read | `bin/digest who` | yes |
| relay ledger `<seat>.seen` | `RELAY_LEDGER` | `${XDG_STATE_HOME:-~/.local/state}/relay/<seat>.seen` | `bin/relay-read` | `bin/relay-read` | **no** |
| out root | `DISPATCH_OUT` | `./dispatch-out` | `bin/dispatch` | the seat that was notified | either, see below |
| runners file | `DISPATCH_RUNNERS` | `<repo>/examples/runners.example.json` | a human | `bin/dispatch` | your call |
| attic | none | `<bus>/_attic/<sweep>-<date>/` | a human or a janitor seat | nobody, until an undo | yes |

Why the ledger stays off the bus: a bus synced to a second machine would otherwise carry the
first machine's read cursor, and a seat there would skip messages it never saw. Consumed-ness is
local. Receipts, by contrast, are *meant* to be seen by everyone, so they stay on the bus.

Why the out tree is "either": `bin/dispatch` records absolute report paths in `meta.json` and
in the relay notice it sends. If the seat that receives the notice runs on another machine,
put the out root under the bus so the path resolves there too. If every seat runs on one
machine, a local out root is fine and keeps large reports out of sync traffic.

## What the bus looks like on disk

```
<bus>/
  DIGEST.md                 one dated, attributed line per event; append only
  digest-reads.jsonl        one JSON object per read: time, seat, lines seen, head hash
  hub/inbox.md              frames closed by ===END===; append only, never rewritten
  worker/inbox.md
  _attic/2026-01-15-sweep/  retired files with MANIFEST.tsv and UNDO.sh; never a delete

<state>/                    per machine, per seat; outside the bus
  relay/hub.seen            one sha256 per consumed frame
  relay/worker.seen

<out>/
  <job>/prompt.md           what the runner was given
  <job>/report.md           what it produced; last line is `===DONE=== <STATUS>`
  <job>/meta.json           runner, status, bytes, timeout, depth, start and end time, report path
  <job>/stderr.log          runner stderr, verbatim; its tail is copied into the report on failure
  <job>/dispatch.log        only for --bg jobs: dispatch's own output
```

`examples/demo.sh` builds exactly this under a scratch directory (`bus/`, `state/`, `out/`) and
keeps it, so the first thing a stranger can do after the one command is `ls` the container.

## Bootstrap contract

What a seat may assume when it starts:

1. The bus root exists, or can be created with `mkdir -p`. Nothing else is guaranteed to exist.
   A missing inbox means no mail. A missing digest means nothing has happened yet. Both are
   normal, not errors.
2. The five coordinates below are set in the environment, identically for every seat on the
   bus. The demo writes them to one file (`seats.sh`) and every seat sources it. Do the same.

   ```sh
   export RELAY_ROOT=<bus>
   export DIGEST_FILE=<bus>/DIGEST.md
   export DIGEST_RECEIPTS=<bus>/digest-reads.jsonl
   export DISPATCH_OUT=<out>
   export DISPATCH_RUNNERS=<your copy of runners.example.json>
   ```

   Set `DIGEST_FILE` explicitly even though it has a default. The digest tool defaults to
   `./DIGEST.md` and dispatch defaults to `<out>/DIGEST.md`; if seats disagree on where the
   digest is, receipts stop meaning anything.
3. The seat's own name and ledger are set by the seat itself, never shared:

   ```sh
   export DIGEST_SEAT=worker DISPATCH_SEAT=worker
   export RELAY_LEDGER=<state>/relay/worker.seen
   ```
4. The tools in `bin/` are on `PATH` or called by path. They need bash 3.2+, coreutils, and
   `jq` or `python3` for the runners file. Nothing else.

What a seat must do on startup, in this order:

1. Read the digest with a receipt: `digest --as <seat>`. Now the bus knows you saw the state.
   A line containing `FAILED` is yours to act on or to hand off, never to ignore.
2. Read your inbox: `relay-read --as <seat>`. Each frame is delivered once; the ledger, not
   the inbox, remembers.
3. Do the work. Hand anything that needs a model to `dispatch` and wait on the sentinel in
   the report file, not on a pid.
4. Leave proof: one digest line per outcome, one relay frame per hand-off. A seat that ends
   without a digest line did nothing, as far as the container is concerned.

What a seat must never do:

- Truncate, rewrite, sort, or "clean up" an inbox, the digest, or the receipts. Append only.
  If a file must go, it goes to the attic with a manifest and an undo script.
- Write consumed-ness onto the bus. The ledger is local.
- Put a hostname, an account name, a person, a token, or an absolute private path into any
  bus file. Seats are names; machines are `node-a` and `node-b` if they must be mentioned at all.
- Write anything after the `===DONE===` line of a report. The sentinel is the end of the file.
- Dispatch below `max_depth`. Agents that fork agents without a floor never finish.

## Adding a machine

Sync the bus directory with any tool that preserves appends (a file-sync daemon, `rsync` on a
timer, a shared mount). Give the new machine its own state directory. Start seats there with
the same five coordinates and their own names and ledgers. Nothing in the bus refers to a
machine, so nothing needs to change when one is added, renamed, or retired.

## Adding a model

Copy `examples/runners.example.json`, add or replace a runner, point `DISPATCH_RUNNERS` at
the copy. Runners are the only place a model is named, so a model change is a one-line diff in
one file, and every contract, report, receipt, and doctrine stays exactly as it was.
