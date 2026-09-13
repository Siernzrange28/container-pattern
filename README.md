# The container pattern

**What this proves:** several agent processes can hand work to each other through plain files and leave proof on disk, with no server, model, or network.
**Who ran it:** a first-time user with only the URL, on a cloud Linux VM, from the README, exit 0, zero friction ([docs/RECEIPTS.md](docs/RECEIPTS.md)).
**Receipts:** CI runs the one-command demo on Ubuntu and macOS on every change; main is protected; every claim the demo makes is checked against the files it wrote.

**The harness is water. The container is the thing.**

Models, agent CLIs, and cloud seats change every few months. What lasts is the *container*
around them: a handful of append-only files on a shared filesystem, and four small contracts
that let several agent seats hand work to each other and leave proof of it on disk.

This repo is that pattern, extracted and sanitized from a system that has run it daily for
months. It needs no particular model, no server, no network, no daemon. If two processes can
read and write the same directory, they can run it.

## The one command

```sh
git clone <this-repo> container-pattern
cd container-pattern
bash examples/demo.sh
```

Needs bash 3.2+, coreutils, and `jq` or `python3`. Nothing else. No model, no tmux, no network.
It runs in a few seconds and exits 0 only when every claim it makes is verified against the
files it wrote. A non-zero exit prints the failing artifact.

What `examples/demo.sh` does, in order:

1. creates a scratch bus directory and keeps it, so you can read every artifact afterwards
2. starts a `worker` seat in its own process, polling its inbox
3. as the `hub` seat, posts one digest line and relays one task to the worker
4. the worker consumes the task by content hash and hands it to a runner via `bin/dispatch`
5. the runner's output lands in a report file whose last line is the `===DONE===` sentinel
6. dispatch posts one digest line and relays the report path back to the hub
7. the hub reads the notice, the report, and the digest, leaving a read receipt
8. `digest who` shows who read what, from disk, not from memory

The default runner is `cat`: it echoes the prompt back. That is deliberate. The pattern is
about the plumbing, and the plumbing is proven with nothing installed.

Useful variants:

```sh
bash examples/demo.sh --tmux                       # worker seat in a tmux session, if tmux exists
bash examples/demo.sh --runner local               # a local model via ollama (see runners file)
bash examples/demo.sh --runners my.json --runner cli   # your own agent CLI
bash examples/demo.sh --dir ./scratch              # choose the scratch directory
```

## What is here

| Path | What it is |
|------|------------|
| `bin/relay-send` | append one message to a peer's inbox; never truncates, never rewrites |
| `bin/relay-read` | consume your inbox by content hash; the ledger lives outside the bus |
| `bin/digest` | the shared one-line-per-event log, with read receipts and `digest who` |
| `bin/dispatch` | hand one job to one runner; get a report file with a sentinel, a deadline, a byte budget, and a depth limit |
| `examples/runners.example.json` | three runners: `stub` (`cat`), `cli` (any agent CLI, placeholder), `local` (ollama) |
| `examples/demo.sh` | the one command above, self-checking |
| `docs/CONTAINER.md` | the roots map and the bootstrap contract: what a seat may assume exists |
| `docs/CONTRACTS.md` | the dispatch contract, the relay protocol, and digest receipts, precisely |
| `docs/DOCTRINE.md` | the rules that survived: maker is never checker, sentinels not pids, never delete |
| `docs/RECEIPTS.md` | proof of operation: dated numbers from the private instance, nothing else |

Every tool is a single bash file with its usage at the top. Read the file before the docs.

## The four contracts in one breath

- **Relay.** Inboxes are append-only files. A message is a frame closed by `===END===`.
  Read state is a hash ledger per reader, kept off the bus, so a synced bus never carries
  another machine's cursor.
- **Digest.** One dated, attributed line per event. Reading it leaves a receipt.
  Silence is not success: a `FAILED` line needs a seat or a human to act on it.
- **Dispatch.** One job, one runner, one report file. The last line is the sentinel and
  nothing is written after it. Wall-clock kill, output cap, and a depth limit are the same
  for every runner, whatever model sits behind it.
- **Receipts.** Every claim is checked against the files, by a process that did not write them.

## Bring your own agent

Copy `examples/runners.example.json`, replace the placeholder command in the `cli` runner
with the CLI you actually have in print mode, point `DISPATCH_RUNNERS` at your copy, and run
the demo with `--runner cli`. Everything else stays the same. That is the point.

## License

Apache 2.0. See `LICENSE`.
