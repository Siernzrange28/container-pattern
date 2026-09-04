#!/usr/bin/env bash
# demo.sh — THE ONE COMMAND. Two seats, one relay bus, one dispatch job, one digest receipt.
#
# Needs: bash 3.2+, coreutils, and jq OR python3 (bin/dispatch reads its runners file with one
# of them). No model, no network, no tmux. Runs in a scratch directory it creates and keeps.
#
# What happens, in order (a few seconds):
#   1. a scratch bus is created and kept, so every artifact can be read afterwards
#   2. seat `worker` starts in its own process and polls its inbox      (bin/relay-read)
#   3. seat `hub` posts to the digest and sends worker ONE task         (bin/digest, bin/relay-send)
#   4. worker consumes the task by hash and hands it to a runner        (bin/dispatch)
#      the runner's output lands in a report file whose LAST line is the ===DONE=== sentinel
#   5. dispatch posts one digest line and relays the report path back to hub
#   6. hub reads the notice, the report, then the digest, leaving a read receipt;
#      `digest who` proves it
#   7. every claim above is checked against the files on disk; exit 0 only if all of them hold
#
#   bash examples/demo.sh                    stub runner: `cat` echoes the prompt, nothing installed
#   bash examples/demo.sh --runner <name>    a runner from runners.example.json (needs its CLI)
#   bash examples/demo.sh --runners <file>   ... or from your own runners file
#   bash examples/demo.sh --tmux             run the worker seat in a tmux session, if tmux exists
#   bash examples/demo.sh --dir <path>       scratch directory (default: mktemp under $TMPDIR)
#
# Exit: 0 = PASS, 1 = a check failed (the failing artifact is printed),
#       2 = usage or missing prerequisite.
set -u
here=$(cd "$(dirname "$0")" && pwd)
self=$here/$(basename "$0")
BIN=$(cd "$here/../bin" && pwd)

runner=stub rfile='' use_tmux=0 dir='' worker_dir=''
while [ $# -gt 0 ]; do
  case "$1" in
    --runner)  runner=${2:?demo: --runner needs a name}; shift 2 ;;
    --runners) rfile=${2:?demo: --runners needs a file}; shift 2 ;;
    --tmux)    use_tmux=1; shift ;;
    --dir)     dir=${2:?demo: --dir needs a path}; shift 2 ;;
    --worker)  worker_dir=${2:?demo: --worker needs the scratch dir}; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "demo: unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done
now()  { date -u +%H:%M:%S; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---- the worker seat: its own process, reads the bus, never talks to hub directly ---------------
if [ -n "$worker_dir" ]; then
  D=$worker_dir
  . "$D/seats.sh"
  export RELAY_LEDGER=$D/state/worker.seen
  export DISPATCH_SEAT=worker DIGEST_SEAT=worker
  log() { printf '%s worker  %s\n' "$(now)" "$*"; }
  frame=$D/state/worker-task.frame
  log "up (pid $$), polling $RELAY_ROOT/worker/inbox.md"
  t=0
  until "$BIN/relay-read" --as worker > "$frame" 2> "$D/state/worker-read.err"; do
    t=$((t + 1)); [ "$t" -le 60 ] || { log "no task arrived in 60s; giving up"; exit 1; }
    sleep 1
  done
  # body = the lines between the second `---` and `===END===` of the first frame
  awk 'BEGIN { s = 0 } /^===END===$/ { exit } s == 2 { print } /^---$/ { s++ }' "$frame" \
    > "$D/state/worker-task.prompt"
  log "task received: $(sed -n 's/^subject: //p' "$frame" | head -n 1)"
  log "dispatch --runner $DEMO_RUNNER --job $DEMO_JOB --notify hub"
  "$BIN/dispatch" --runner "$DEMO_RUNNER" --job "$DEMO_JOB" --notify hub --timeout 60 \
    --prompt-file "$D/state/worker-task.prompt" > "$D/state/worker-dispatch.out" 2>&1
  rc=$?
  log "dispatch exit $rc: $(tail -n 1 "$D/state/worker-dispatch.out")"
  "$BIN/digest" --as worker > /dev/null 2>&1 && log "digest read; receipt left"
  : > "$D/state/worker.done"
  exit "$rc"
fi

# ---- the hub seat: prerequisites ----------------------------------------------------------------
missing=''
have jq || have python3 || missing="$missing jq-or-python3"
have sha256sum || have shasum || missing="$missing sha256sum-or-shasum"
for c in awk sed mktemp head tail wc date sleep; do have "$c" || missing="$missing $c"; done
[ -z "$missing" ] || { echo "demo: missing prerequisites:$missing" >&2; exit 2; }
for t in dispatch relay-send relay-read digest; do
  [ -x "$BIN/$t" ] && continue
  chmod +x "$BIN/$t" 2>/dev/null || { echo "demo: $BIN/$t is not executable" >&2; exit 2; }
done
if [ -n "$rfile" ]; then
  [ -f "$rfile" ] || { echo "demo: no runners file at $rfile" >&2; exit 2; }
  rfile=$(cd "$(dirname "$rfile")" && pwd)/$(basename "$rfile")
fi
rfile=${rfile:-${DISPATCH_RUNNERS:-$here/runners.example.json}}
if ! DISPATCH_RUNNERS=$rfile "$BIN/dispatch" runners | grep -q "^$runner[[:space:]]"; then
  echo "demo: no runner '$runner' in $rfile. Have:" >&2
  DISPATCH_RUNNERS=$rfile "$BIN/dispatch" runners >&2
  exit 2
fi

# ---- the scratch bus ----------------------------------------------------------------------------
if [ -n "$dir" ]; then
  mkdir -p "$dir" || exit 2
  D=$(cd "$dir" && pwd)
else
  D=$(mktemp -d "${TMPDIR:-/tmp}/container-demo.XXXXXX") || exit 2
fi
mkdir -p "$D/bus" "$D/state" "$D/out"
JOB="demo-$(date -u +%H%M%S)-$$"
TOKEN="pong-$$-$RANDOM"
# seats.sh: the bus coordinates both seats share; each seat adds its own ledger and name on top
printf 'export %s=%q\n' \
  RELAY_ROOT "$D/bus" DIGEST_FILE "$D/bus/DIGEST.md" \
  DIGEST_RECEIPTS "$D/bus/digest-reads.jsonl" DISPATCH_OUT "$D/out" DISPATCH_RUNNERS "$rfile" \
  DEMO_RUNNER "$runner" DEMO_JOB "$JOB" BIN "$BIN" \
  > "$D/seats.sh"
. "$D/seats.sh"
export RELAY_LEDGER=$D/state/hub.seen DIGEST_SEAT=hub
report=$DISPATCH_OUT/$JOB/report.md

# ---- start the worker seat ----------------------------------------------------------------------
session="container-demo-$$" WPID='' mode=''
if [ "$use_tmux" = 1 ]; then
  wcmd="bash $(printf '%q' "$self") --worker $(printf '%q' "$D")"
  wcmd="$wcmd > $(printf '%q' "$D/worker.log") 2>&1"
  if have tmux && tmux new-session -d -s "$session" "$wcmd"; then
    mode="tmux session '$session'"
  else
    echo "demo: tmux unavailable or refused; the worker runs as a background job instead" >&2
    use_tmux=0
  fi
fi
if [ "$use_tmux" = 0 ]; then
  bash "$self" --worker "$D" > "$D/worker.log" 2>&1 & WPID=$!
  mode="background job, pid $WPID"
fi
worker_alive() {
  if [ -n "$WPID" ]; then kill -0 "$WPID" 2>/dev/null
  else tmux has-session -t "$session" 2>/dev/null; fi
}
cleanup() {
  worker_alive || return 0
  if [ -n "$WPID" ]; then kill "$WPID" 2>/dev/null
  else tmux kill-session -t "$session" 2>/dev/null; fi
}
trap cleanup EXIT

# ---- the hub seat: one task out, one report back ------------------------------------------------
say()  { printf '%s hub     %s\n' "$(now)" "$*"; }
show() { sed 's/^/        | /'; }
fail() {
  echo "FAIL  $*"
  echo "--- worker.log (last 20 lines)"; tail -n 20 "$D/worker.log" 2>/dev/null
  if [ -s "$report" ]; then echo "--- $report (last 20 lines)"; tail -n 20 "$report"; fi
  echo "artifacts kept under $D"; exit 1
}
echo "== container demo ==  scratch: $D"
echo "   seats: hub (this process) + worker ($mode)   runner: $runner   job: $JOB"
say "digest post"
"$BIN/digest" post --as hub "task $JOB queued for worker (runner=$runner)" | show
say "relay-send hub -> worker"
printf 'Demo task. Reply with exactly this token and nothing else: %s\n' "$TOKEN" \
  | "$BIN/relay-send" --from hub --to worker --subject "task $JOB: reply with the token" | show
say "waiting for the worker's notice in $RELAY_ROOT/hub/inbox.md (a file, not a pid)"
t=0
while [ "$("$BIN/relay-read" --as hub --count 2>/dev/null || echo 0)" = 0 ]; do
  worker_alive || [ -e "$D/state/worker.done" ] || fail "worker exited before reporting"
  t=$((t + 1)); [ "$t" -le 90 ] || fail "no notice from the worker within 90s"
  sleep 1
done
say "relay-read hub: the notice"
"$BIN/relay-read" --as hub | show
say "dispatch status $JOB (reads the sentinel, never the process table)"
"$BIN/dispatch" status "$JOB" --wait 10 | show
say "the report: $report"
show < "$report"
t=0
while [ ! -e "$D/state/worker.done" ]; do
  t=$((t + 1)); [ "$t" -le 15 ] || fail "worker never finished (no worker.done)"; sleep 1
done
say "digest read as hub (leaves a receipt)"
"$BIN/digest" --as hub -n 5 | show
say "digest who"
"$BIN/digest" who | show

# ---- checks: the claims above, verified against the disk ----------------------------------------
echo
echo "== checks =="
nfail=0
check() {
  local label=$1; shift
  if "$@" >/dev/null 2>&1; then echo "  ok    $label"
  else echo "  FAIL  $label"; nfail=$((nfail + 1)); fi
}
none()         { ! grep -q "$@"; }
both_current() {
  "$BIN/digest" who | awk '$1 == "hub"    && $NF == "current" { h = 1 }
                           $1 == "worker" && $NF == "current" { w = 1 }
                           END { exit !(h && w) }'
}
last=$(tail -n 1 "$report" 2>/dev/null)
check "report exists and is not empty"                    test -s "$report"
check "report's last line is ===DONE=== OK (got: $last)"  test "$last" = "===DONE=== OK"
[ "$runner" != stub ] || check "stub echoed the token $TOKEN into the report" \
  grep -q "$TOKEN" "$report"
check "meta.json records status OK"        grep -q '"status":"OK"' "$DISPATCH_OUT/$JOB/meta.json"
check "hub's inbox holds 'job $JOB OK'" \
  grep -q "^subject: job $JOB OK\$" "$RELAY_ROOT/hub/inbox.md"
check "hub consumed it: 0 unread"          test "$("$BIN/relay-read" --as hub --count)" = 0
check "worker's inbox still holds the task (append-only, never rewritten)" \
  grep -q "^subject: task $JOB:" "$RELAY_ROOT/worker/inbox.md"
check "digest has the job line"            grep -q "job $JOB OK" "$DIGEST_FILE"
check "digest has no FAILED line"          none FAILED "$DIGEST_FILE"
check "receipt: worker read the digest"    grep -q '"seat":"worker"' "$DIGEST_RECEIPTS"
check "receipt: hub read the digest"       grep -q '"seat":"hub"' "$DIGEST_RECEIPTS"
check "digest who: both seats current"     both_current
echo
if [ "$nfail" = 0 ]; then
  echo "PASS  two seats, one bus, one job, one receipt. Everything above is on disk:"
  find "$D" -type f | sort | sed "s|^$D/|        |"
  exit 0
fi
fail "$nfail check(s) failed"
