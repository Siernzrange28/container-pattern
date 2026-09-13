# Case study: running an agent fleet like a production system

Eight months of operating a personal multi-agent system on one Linux box: what it is, what broke, what was measured, and what changed because of the numbers. Every figure below came from files the system writes about itself; nothing is estimated. Names of private files and money figures are left out on purpose.

## The system, in numbers
| thing | count | how it is known |
|---|---|---|
| command-line tools in the toolkit | 208 | file inventory |
| tools instrumented with a usage log line | 206 of 207 | instrumenter manifest, verified by hash |
| scheduled jobs (cron) | 47 | crontab |
| services that come back after a reboot | 9 | systemd user units |
| agent "seats" on the board | 9 tmux windows, 4 with a live model | `faces status --json` |
| exchange-facing tools in one lane | 84, of which 29 can place orders | lane audit |
| tool calls logged in 30 days | 72,266 | usage log |

## What broke, and the fix that was measured
**1. Dead jobs that looked alive.** Each cron line redirected output to a `.cron.log`; the file's modification time was taken as proof the job ran. It was not: the shell touches the file whether or not the job does anything. Fix: read the cron daemon's own syslog line for each job (the only receipt cron writes), fall back to the tool's own log, then to the redirect. Verdicts changed for several jobs on the first run.

**2. A corrupt queue that reported "empty".** The inbound queue loader caught every exception and returned an empty list. A corrupted JSON file therefore looked like "nothing to do" for days. Fix: catch only file-not-found; anything else exits 2 with a message. Test: a fixture with a truncated file must fail before the change and pass after. This was the first *safety net* in a system that was, by count, almost entirely *guard rails*.

**3. Telemetry blind spots.** Before instrumentation, 178 of 217 tools had no usage record, so "unused, delete it" was a guess. After: every tool logs one line per call; the 30-day report separates ZERO-USE from "too new to judge" (a 30-day observation window after instrumentation) so nothing is retired on a technicality. 95% of logged calls turned out to belong to one lane.

**4. A seat that died silently.** An agent CLI self-updated mid-task and exited to a bare shell; the next task was typed into a dead pane and sat for 55 minutes. Fix: a per-window liveness check (`faces status`, exit 1 when a configured seat is not running) and a revive verb that re-sends the launch command only to an observed empty shell, never to the human's window. 17 isolated tmux tests.

**5. Giving profits back.** In one lane, every winning day was handed back inside the same day with positions still open. A trailing "take" observer (arm at +25%, take at 50% give-back or +100%, lock the day) was built dry-run first, replayed on the recorded series, and left disabled until the owner promotes it. The replay is engineering evidence, not a claim of edge; the honest note in the receipt says so.

## How work is assigned and checked
- **Maker ≠ checker.** A brief (context, no-compromise rails, opinions labelled as opinions, audit-first, stop-if-simple, gates, receipt) goes to a builder seat. A different seat reruns the tests and commits. Builder seats never commit.
- **Red before green.** Every change carries a test that fails before it and passes after. A change without a red log is not reviewed.
- **Receipts wake the reviewer; panes do not.** A watcher waits for the receipt file, not for the model to say it is done.
- **Never delete.** Retired things go to an attic with a manifest of hashes; an undo script is written before the edit.
- **Owner decisions are one word.** Anything that changes money, doctrine, or the schedule is written as a proposal and waits for the owner's `go`, `no`, or `alert`.

## What I would do differently
Fewer tools, earlier. Telemetry on day one, not month seven. Safety nets (detect and undo) before guard rails (prevent). And one public, runnable slice of the pattern from the start, because packaging was the habit that was missing, not building.

## Provenance
Written 2026-09-13 from the system's own audit documents and commit history. The runnable pattern this repo demonstrates is the same one the fleet uses; the demo is sanitized, the numbers above are not.
