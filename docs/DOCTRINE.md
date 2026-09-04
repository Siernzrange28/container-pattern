# Doctrine

The rules that survived months of running the container daily with several agent seats. Rules
only, no stories. Each one says what the rule is, why it exists, and whether the shipped tools
enforce it or it stays doctrine (a rule humans and seats follow because the tools cannot check
it). Vocabulary is defined in `docs/CONTAINER.md`; wire formats in `docs/CONTRACTS.md`.

Two words used throughout:

- **Claim.** Anything a seat, a runner, or a person says happened.
- **Proof.** A file the contract wrote, checked by a process that did not write it.

## A. Proof

### A1. Maker is never checker

**Rule.** The process that produced a result does not verify it. Verification is a separate
process, ideally with fresh context, that reads only files.

**Why.** A maker grades its own work generously, and a model grades its own work with the same
blind spots that produced it. The check has to come from somewhere the mistake did not.

**Enforced by.** `examples/demo.sh`: the worker seat writes, the hub seat reads, and the check
block is a third piece of code that touches only the disk. `bin/dispatch` writes the sentinel
from outside the runner, after the runner has exited. Beyond that: doctrine.

### A2. Wait on the sentinel, not on the pid

**Rule.** "The process is running" is not success, and "the process exited" is not completion.
A job is done when the last line of its report is `===DONE=== <STATUS>`, and only then.

**Why.** Processes hang, get killed, exit 0 after writing nothing, or write half a file. The
only signal that cannot be misread is a line that is written last, once, by the contract.

**Enforced by.** `bin/dispatch` appends the sentinel after the runner exits and writes nothing
after it. `dispatch status <job>` reads the sentinel, never the process table.

### A3. Silence is not success

**Rule.** A finished job leaves a digest line. A failed one leaves a line starting with
`FAILED:`. A digest with no line means nothing happened, not that things went fine. A
`FAILED` line is a task for a seat or a human until someone acts on it.

**Why.** Monitors that only speak on failure go quiet when they die. The absence of a signal
then looks identical to "all good".

**Enforced by.** `bin/dispatch` posts one digest line per finished job, prefixed `FAILED:`
unless the status is OK. `bin/digest` warns on stderr whenever it prints a `FAILED` line.
Acting on the line: doctrine.

### A4. Leave proof before you stop

**Rule.** A seat ends its turn only after the proof of what it did is on disk: the sentinel
for a job, the frame for a hand-off, the digest line for an event, the receipt for a read.
A turn that ends on a claim in memory did not happen.

**Why.** Seats lose context at every restart. The next seat, or the same one an hour later,
has only the files. Anything not written is gone.

**Enforced by.** The bootstrap contract in `docs/CONTAINER.md` (read with receipt, consume,
work, leave proof). `bin/digest` records the receipt as a side effect of reading, so a seat
cannot read without proving it did. Ending the turn correctly: doctrine.

### A5. Absence is a finding

**Rule.** A seat with no receipt did not read. A report with no sentinel is not done. A
hand-off with no frame did not happen. A check with nothing to check fails.

**Why.** Inferring success from a missing failure is the most common way a fleet drifts.
Every proof in the container is positive: something that exists, not something that did not.

**Enforced by.** `digest who` lists only seats that left a receipt, and marks seats behind the
digest as `N behind`; a seat not in the list did not read. `examples/demo.sh` fails on any
missing artifact. Beyond that: doctrine.

### A6. A seat's report about itself is a claim

**Rule.** What a seat says about its own environment, its own progress, or its own success is
a claim. Verify it from a shell the seat does not control before acting on it.

**Why.** Sandboxed and remote seats routinely misreport what they can see, what is installed,
and what they wrote. Restart and configuration decisions taken on those reports break things
that were fine.

**Enforced by.** Not enforced: doctrine. The receipts table in `docs/CONTRACTS.md` lists what
can be checked from outside.

## B. Files

### B1. Append only, never truncate, never rewrite

**Rule.** Shared files on the bus (inboxes, the digest, receipts) are only ever appended to.
No tool truncates them, rewrites them in place, or removes consumed content.

**Why.** Two seats writing the same file survive appends and lose data on rewrites. A synced
bus makes it worse: a rewrite on one machine races an append on another. History on disk is
also the audit trail; removing consumed frames deletes the proof that they were sent.

**Enforced by.** `bin/relay-send` writes one frame in one append. `bin/relay-read` never
opens the inbox for writing; read state lives in a separate ledger. `bin/digest` appends
lines and receipts only. `examples/demo.sh` checks that the worker's inbox still holds the
task after it was consumed.

### B2. Never delete: retire to the attic

**Rule.** Nothing on the bus or in the out tree is deleted. Files that are done are moved to
`<bus>/_attic/<date>-<sweep>/` together with a `MANIFEST.tsv` (what moved from where) and an
`UNDO.sh` that puts everything back.

**Why.** Every deletion that later turned out to matter was done with confidence. A move with
an undo script costs a directory and removes the whole class of mistake.

**Enforced by.** No tool in `bin/` deletes or truncates anything. The attic layout itself:
doctrine.

### B3. Read state stays off the bus

**Rule.** Which frames a seat has consumed is per seat and per machine. It lives in a ledger
outside the bus, never in the inbox, never in a shared file.

**Why.** A bus may be synced between machines. A cursor that travels with it makes a seat on
the second machine skip messages it never saw. Consumed-ness is local by nature.

**Enforced by.** `bin/relay-read` defaults its ledger to a per-user state directory and
nothing in the tools ever points it at the bus; the override is explicit and yours to keep
off the bus. Receipts, which are meant to be seen by everyone, stay on the bus by the same
reasoning in reverse.

### B4. Names never encode a host, an account, or a person

**Rule.** Seat names, runner names, and job ids are plain roles: `hub`, `worker`, `reviewer`,
`stub`. They never contain a hostname, a username, an email, an address, or a person's name.

**Why.** Names end up in every frame, every digest line, every report, and every receipt. A
name tied to an account leaks the account wherever the bus goes, and it stops being true the
day the account changes. Roles survive; identities do not.

**Enforced by.** Every tool validates names against `[A-Za-z0-9][A-Za-z0-9_.-]*`. A publish
check greps the whole tree for private paths, hostnames, and tailnet addresses before any
push. Choosing role names: doctrine.

### B5. Intent and proof live in different files

**Rule.** What a seat is asked to do goes over the relay, addressed to that seat. What
happened goes to the digest, attributed to the seat that did it. Neither channel carries the
other kind of line.

**Why.** A task list that also holds status lines becomes unreadable within a day, and a
status log that also holds tasks lets work get lost in it. One channel for intent, one for
receipts, and `digest who` tells you who has seen which.

**Enforced by.** `bin/relay-send` frames are addressed to one seat; `bin/digest` lines are
attributed to one seat. Keeping the content on the right channel: doctrine.

### B6. Errors travel verbatim

**Rule.** A runner's stderr goes into its job directory unchanged, and its tail is copied
into the report on failure. Tools never swallow, paraphrase, or summarise an error.

**Why.** The seat that has to fix the problem is usually not the seat that saw it. A
paraphrased error is a guess about what mattered, made by the party least able to judge.

**Enforced by.** `bin/dispatch` writes `stderr.log` verbatim and appends its tail to the
report when the status is not OK. All tools print their own errors to stderr and exit non-zero.

## C. Bounds

### C1. Every job has a wall clock, a byte budget, and a depth

**Rule.** No job runs without a deadline, an output cap, and a depth limit. The limits are the
same for every runner, whatever model sits behind it, and are set by the dispatcher, not the
runner.

**Why.** Models do not stop by themselves. Tokens, seconds, and dollars differ by provider;
bytes and seconds are the currency every runner shares. Depth is the one that matters most: an
agent that can dispatch agents will, and without a floor the fleet forks until something
external kills it.

**Enforced by.** `bin/dispatch`: TERM at the deadline and KILL five seconds later
(`TIMEOUT`); output capped at the budget (`OVER_BUDGET`); `DISPATCH_DEPTH` grows by one per
level and dispatch refuses above `max_depth` before writing anything.

### C2. A failed runner is a routing event, not a retry loop

**Rule.** When a runner fails, the caller retries at most once, then falls to the next runner
down the ladder, and the report records which runner actually produced the output.

**Why.** Retrying a dead seat burns the budget and hides the outage. Falling back keeps the
work moving and turns the failure into one digest line instead of a stall.

**Enforced by.** `bin/dispatch` exits 1 with the status in the report and the runner name in
`meta.json`; it never retries on its own. The ladder and the single retry: doctrine.

### C3. Loops have an objective stop and a hard ceiling

**Rule.** Any loop that runs unattended has a stop condition that a file check can decide, a
maximum number of iterations, a maximum budget, and a stall rule: if an iteration changes
nothing, the loop halts and says so.

**Why.** "Until it works" is not a stop condition. A loop without a ceiling is a bill without
a cap, and a loop that spins without progress looks alive while doing nothing.

**Enforced by.** Not enforced by the tools: doctrine. `bin/dispatch` gives each iteration its
own bounds (C1); the loop's own ceiling and stall rule belong to the loop.

### C4. The prompt is the whole context

**Rule.** A runner receives the prompt and nothing else. The prompt carries the goal (an
outcome, not an action), the constraints (what not to do), the exact deliverable and its path,
and the failure rule ("if a tool fails twice, stop and report; if unclear, ask one consolidated
question, never guess").

**Why.** A fresh process has no memory of the conversation that produced the task. Anything
the dispatcher assumes the runner knows, the runner does not know.

**Enforced by.** `bin/dispatch` hands the runner only the prompt (on stdin and in a file) and
a fixed set of `DISPATCH_*` variables. Writing a complete prompt: doctrine.

### C5. Stable prefix, variable tail

**Rule.** Prompts and tool headers that are sent repeatedly keep their fixed part first and
put what changes at the end.

**Why.** Cheap seats cache the prompt prefix. Reordering the head invalidates the cache and
multiplies the cost of every call for no gain.

**Enforced by.** Not enforced: doctrine.

## D. Change

### D1. Red test first

**Rule.** Write the check that fails before the change that makes it pass. A check that has
never been seen failing proves nothing.

**Why.** A check written after the fact is shaped by the implementation and passes by
construction. The failing run is the only evidence that the check can detect the problem.

**Enforced by.** `examples/demo.sh` is written so every check reads an artifact that would
be absent if its step had not run; skip a step and the check goes red. Applying the rule to
new work: doctrine.

### D2. Freeze additions while a loop is open

**Rule.** While a loop is running to completion, nothing new is added: no new tool, no new
seat, no new file kind, no new signal. Fix or finish, then add.

**Why.** Every addition made during a loop widens the target the loop is trying to hit. The
loop then never closes, and the additions never get their own loop either.

**Enforced by.** Not enforced: doctrine. The container helps by making the two things that do
change often, the model and the machine, one-line edits: a runner in the runners file, a root
in the environment.

### D3. Every signal earns its place: keep the kill list

**Rule.** A metric, a monitor, a log line, or a page exists only if someone acts on it. Review
the set; kill what no one acts on; keep a dated list of what was killed and why so it is not
re-added by the next enthusiast. The default answer to a new signal is no.

**Why.** Signals accumulate, attention does not. Past a point, the important line is buried
among lines nobody reads, and the whole channel gets ignored.

**Enforced by.** Not enforced: doctrine. The container ships exactly three signals, one
digest line per event, one receipt per read, one sentinel per job, and nothing in `bin/`
emits anything else.

### D4. Monitors page on failure class only

**Rule.** A monitor fails loudly, excludes its own output from what it watches, and pages only
for the failure class it was built for. Routine findings go to a log, not to a person.

**Why.** A monitor that pages on routine gets muted. A monitor that watches its own output
pages itself forever. A monitor that fails silently is A3 again.

**Enforced by.** Not enforced: doctrine. `bin/digest` gives monitors `--no-receipt` so their
reads do not count as a seat having seen the state.

### D5. Doctrine is human-owned

**Rule.** This file, and any file like it that tells seats how to behave, is edited by a
person. Seats audit it, propose diffs, and say what they would change and why. They do not
apply the change.

**Why.** A seat that can rewrite its own rules will, in good faith, rewrite them toward what
it was already going to do. The rules are the one thing that has to be outside the loop.

**Enforced by.** Not enforced: doctrine.

## E. Boundary

### E1. The boundary is a human

**Rule.** Nothing in the container talks to the outside world by itself. Anything that must
cross the boundary in either direction is carried by a person: a paste, a file drop, an
explicit command. Anything that spends money, sends a message outward, or cannot be undone
sits behind that same human gate.

**Why.** A boundary enforced by configuration can be misconfigured. A boundary enforced by a
person pasting a file cannot. Low volume across it is the point, not a cost.

**Enforced by.** No tool in `bin/` opens a network connection; the bus is a directory. The
gate for spend and outward sends: doctrine.

### E2. The pattern has no memory of the person

**Rule.** The public pattern knows the roles, the files, and the contracts. It never knows
who runs it: no name, no host, no account, no path from a private machine, nothing about
health, money, or work.

**Why.** That is what makes it publishable, forkable, and true after the person's setup
changes. A pattern that only works on one desk is a setup, not a pattern.

**Enforced by.** The publish check in B4, run over the whole tree before every push. Writing
docs and examples with placeholders in the first place: doctrine.

## Reading order for a new seat

1. `docs/CONTAINER.md` for what exists and what a seat may assume.
2. This file for what a seat must and must not do.
3. `docs/CONTRACTS.md` when the exact bytes matter.
4. `docs/RECEIPTS.md` to see that it has run.
