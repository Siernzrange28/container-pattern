# RECEIPTS — proof of operation

Dated numbers only. Every figure names the file or command that produced it and how a reader
can re-count it. A number without a date, a source, and a re-check path does not belong here.
Figures are updated in place with a new date, never averaged, never extrapolated.

Two kinds of receipt live in this file:

1. **The repo's own.** Produced by `bash examples/demo.sh` on a stated date. Anyone can reproduce
   them on any machine with bash, coreutils, and `jq` or `python3`.
2. **The private instance's.** Counted by the owner on machines this repo knows nothing about.
   Nothing here can verify them. They are stated as claims with a date and a counting method.
   Where the owner has not yet supplied a figure the cell says `TBD by owner`. No cell is estimated.

Per `docs/DOCTRINE.md` a seat's self-report is a claim, so section 1 is a claim by this repo about
itself. The receipt that counts is your own run. Section 4 is where a stranger's run gets logged.

## 1. This repo, run on 2026-09-03

Command: `bash examples/demo.sh --dir <scratch>` at commit `6b86408`, the tree just before this
file was added. Default runner `stub` (`cat`), worker as a background job (no `--tmux`).
Environment: Linux x86_64, GNU bash 5.2.21, `jq` and `sha256sum` present. No network.

| Measure | Value | Source on disk |
|---------|-------|----------------|
| exit code | 0 | shell `$?` |
| checks run / passed | 12 / 12 | `== checks ==` block of stdout; the `check "` lines in `examples/demo.sh` |
| wall clock, start to `PASS` | 2.1 s | shell timing around the command; both seats poll at 1 s |
| seats | 2 (`hub`, `worker`) | `worker.log`, `digest who` |
| relay frames sent | 2 (task hub→worker, notice worker→hub) | `bus/worker/inbox.md` 200 B, `bus/hub/inbox.md` 258 B |
| frames consumed | 2, one per seat | `state/worker.seen`, `state/hub.seen`: one 64-hex hash each |
| unread for hub after the run | 0 | `relay-read --as hub --count` |
| inbox rewrites | 0 | worker's inbox still holds the task frame after consumption |
| digest lines | 2 (hub post, worker job line) | `bus/DIGEST.md` 226 B |
| digest receipts | 2, one per seat, both `lines:2`, same head `ef5a8c0424a7` | `bus/digest-reads.jsonl` 157 B |
| `digest who` | `hub current`, `worker current` | `digest who` |
| `FAILED` lines in the digest | 0 | check "digest has no FAILED line" |
| dispatch jobs | 1, status OK, exit 0, 78 B of output, 0 s | `out/<job>/meta.json` 294 B |
| report's last line | `===DONE=== OK` | `out/<job>/report.md` 299 B; nothing follows the sentinel |
| runner stderr | 0 B | `out/<job>/stderr.log` |
| files left on disk | 17 | the `find` listing printed under `PASS` |
| network calls | 0 | no tool in `bin/` invokes curl, wget, nc, or ssh (`grep -lE 'curl|wget|nc |ssh' bin/*` is empty) |

Timeline from the artifacts, UTC, all on 2026-09-03: 22:30:19 hub posts and sends. 22:30:20 worker
receives. 22:30:21 report written, notice sent, worker receipt left. 22:30:22 hub reads and leaves
its receipt. Three seconds, file to file, on a 1 s poll.

To re-check: run the command and compare. Everything in the table should match except wall clock,
the job id, pids, and the hashes (a frame's hash covers its timestamp, so it differs per run).

## 2. The repo at the same commit

| Measure | Value | Source |
|---------|-------|--------|
| tools in `bin/` | 4 files, 459 lines of bash, no other language | `wc -l bin/*` |
| `examples/demo.sh` | 217 lines, 12 checks | `wc -l`, `grep -c 'check "'` |
| `docs/` before this file | 3 files, 805 lines | `wc -l docs/*.md` |
| runtime dependencies | bash 3.2+, coreutils, `jq` or `python3` | header of `examples/demo.sh` |
| publish check, 2026-09-03 | 0 hits | `grep -rEn` over the tree (minus `.git`) for private path prefixes, account and node names, tailnet IP ranges and the tailnet DNS suffix |

## 3. The private instance (owner-counted, not verifiable from this repo)

The pattern was extracted from one instance that has run it daily for eight months as of 2026-09-01
(owner's statement in the project brief of that date). Figures below are the owner's counts.
A row enters this table with a date and a counting command and is updated in place.

| Figure | Value | Counted on | How counted |
|--------|-------|------------|-------------|
| dispatch reports on disk | 89 | 2026-09-01 | report files under the dispatch out root; `find <out> -name report.md \| wc -l` |
| telemetry signals before the kill-list pass | 32 | 2026-09-01 | owner's list at the start of the pass |
| telemetry signals kept after the pass | TBD by owner | | same list after the pass |
| relay frames on the bus | TBD by owner | | `grep -c '^===END===$' <bus>/*/inbox.md` |
| digest read receipts | TBD by owner | | `wc -l <bus>/digest-reads.jsonl` |
| scheduled entries driving the bus | TBD by owner | | `crontab -l \| grep -vc '^#'` per machine, summed |
| machines sharing one bus | TBD by owner | | distinct `seat` values in `digest-reads.jsonl` mapped to machines by the owner |
| uptime of the status board | TBD by owner | | the board's own log; first and last timestamp |

## 4. The stranger test

Done means: someone with only this repo's URL runs the one command green on a machine the owner
has never touched. Each attempt is logged here verbatim, friction included. An empty table means
the definition of done has not been met yet.

| Date | Runner | Machine | Result | Friction, verbatim |
|------|--------|---------|--------|--------------------|
| 2026-09-04 | Grok Bot, given only the URL | cloud Linux VM, bash 5.2.37, not the owner's | exit 0 | none |

Notes the stranger left after reading the docs (verbatim, one per doc; not friction, kept as candidates):
- CONTAINER.md: "DIGEST_FILE defaults to ./DIGEST.md and dispatch defaults to <out>/DIGEST.md" is a landmine unless you already ran the demo.
- CONTRACTS.md: depth limit and byte budget feel under-motivated without a failed-run example in the doc itself.
- DOCTRINE.md: attic/never-delete is asserted without a demo step that forces a retirement.
- RECEIPTS.md: the private-instance numbers cannot be verified from this public clone, only asserted.
- Reuse: "Yes for a local two-seat bus on one machine; the hard part is waking on inbound notices, which this pattern does not solve by itself."

## 5. Hosted runners (not a stranger, but not the owner's machine either)

Every push and pull request runs the one command on two hosted runners the owner never touches
(`.github/workflows/demo.yml`). A green check is a fresh-checkout run of `examples/demo.sh`.

| Date (UTC) | Runner | Result | Run |
|------------|--------|--------|-----|
| 2026-09-04 | ubuntu-latest | exit 0, 8 s | actions/runs/33824358482/job/100873717824 |
| 2026-09-04 | macos-latest (system bash) | exit 0, 12 s | actions/runs/33824358482/job/100873717612 |

## 6. Pull requests through the check

`main` accepts a merge only when both runners are green (branch protection, strict). One row per
merged PR, the columns a maintainer needs to see whether the check is earning its place.
Counted from `gh pr view <n> --json additions,deletions,changedFiles,commits,comments,createdAt,mergedAt`.

| PR | Files | +/− | Commits after open | Review comments | Open → merge | Checks |
|----|-------|-----|--------------------|-----------------|--------------|--------|
| #1 | 1 | +13 / −0 | 0 | 0 | 48 s | 4 of 4 green |
