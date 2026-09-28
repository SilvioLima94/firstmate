#!/usr/bin/env bash
# Live lab for the fm-teardown pool-return fix.
# Usage: live-lab.sh <firstmate-tree> <label> [slow-secs]
# Builds a disposable lab home, a throwaway origin/project, a REAL treehouse
# pool (TREEHOUSE_ROOT inside the lab), a REAL tmux server on the lab's private
# socket whose fm-task-x1 window runs a REAL interactive `treehouse get`
# holder with a worker inside the slot, lands the task's work on origin/main
# (squash-merge shape), then runs the given tree's REAL bin/fm-teardown.sh from
# inside the lab tmux server. Only gh/gh-axi/no-mistakes are stubbed (the
# origin is a local path, so there is no GitHub PR or gate run to query).
# Everything is removed at the end.
set -u
TREE=$1 LABEL=$2 SLOW=${3:-2}
EVDIR=$(cd "$(dirname "$0")" && pwd)
OUT="$EVDIR/live-$LABEL.log"
: > "$OUT"
log() { printf '%s\n' "$*" | tee -a "$OUT"; }
WT_REPO=/Users/young/.no-mistakes/worktrees/ddd7aba8785a/01M3MXVAH57A3TG7GA5NTA6072

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT_REPO/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
LAB=$(cd "$LAB" && pwd -P)
TMUXD=$("$WT_REPO/bin/fm-lab-home.sh" tmux-dir "$LAB") || exit 1
tm() { TMUX_TMPDIR="$TMUXD" tmux -L fm-lab "$@"; }
cleanup() {
  [ -n "${SAMPLER:-}" ] && kill "$SAMPLER" 2>/dev/null
  tm kill-server 2>/dev/null
  "$WT_REPO/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1
  pkill -f "$LAB/" 2>/dev/null
  rm -rf "$LAB"
}
trap cleanup EXIT
log "== live lab [$LABEL] teardown tree: $TREE"
log "treehouse $(treehouse --version) / $(tmux -V) / $(git --version)"

# --- throwaway repo -------------------------------------------------------
git init -q --bare "$LAB/origin.git"
git -C "$LAB/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$LAB/origin.git" "$LAB/seed" 2>/dev/null
for d in $(seq 1 20); do mkdir -p "$LAB/seed/src$d"; for f in $(seq 1 100); do echo "$d/$f" > "$LAB/seed/src$d/f$f.txt"; done; done
git -C "$LAB/seed" add -A
git -C "$LAB/seed" -c user.email=t@t -c user.name=t commit -qm "baseline (2000 files)"
git -C "$LAB/seed" push -q origin main
PROJ="$LAB/projects/demo"
git clone -q "$LAB/origin.git" "$PROJ"
git -C "$PROJ" remote set-head origin main >/dev/null 2>&1
# Slow ONLY git steps whose parent is a treehouse process (the holder's own
# return), keeping them real `git` processes - the masking condition.
cat > "$LAB/slow-fsmonitor.sh" <<SH
#!/bin/bash
gp=\$(ps -o ppid= -p \$PPID | tr -d ' ')
case "\$(ps -o comm= -p "\$gp")" in *treehouse*) sleep $SLOW ;; esac
exit 1
SH
chmod +x "$LAB/slow-fsmonitor.sh"
git -C "$PROJ" config core.fsmonitor "$LAB/slow-fsmonitor.sh"

# --- stubs for external services only ---------------------------------------
STUBS="$LAB/stubs"; mkdir -p "$STUBS"
cat > "$STUBS/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
cat > "$STUBS/gh" <<'SH'
#!/usr/bin/env bash
echo "error: pull request not found" >&2; exit 1
SH
cat > "$STUBS/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$STUBS"/*

# --- real tmux + real interactive treehouse get ------------------------------
tm new-session -d -s firstmate -n fm-task-x1 -x 200 -y 50 -c "$PROJ" \
  -e TREEHOUSE_ROOT="$LAB/pool" -e PS1='$ ' "/bin/bash --noprofile --norc"
sleep 0.5
tm send-keys -t firstmate:fm-task-x1 'treehouse get' Enter
SLOT=
for _ in $(seq 1 120); do
  p=$(tm display-message -p -t firstmate:fm-task-x1 '#{pane_current_path}')
  case "$p" in "$LAB/pool"*|/private"$LAB/pool"*) SLOT=$p; break ;; esac
  sleep 0.5
done
[ -n "$SLOT" ] || { log "FAILED: treehouse get never entered a slot"; tm capture-pane -p -t firstmate:fm-task-x1 >> "$OUT"; exit 1; }
SLOT=$(cd "$SLOT" && pwd -P)
log "slot acquired by real 'treehouse get': $SLOT"
tm send-keys -t firstmate:fm-task-x1 "git switch -q -c fm/task-x1 && echo feature > feature.txt && git add feature.txt && git -c user.email=t@t -c user.name=t commit -qm 'add feature' && echo WORKER-READY && sleep 900" Enter
for _ in $(seq 1 60); do tm capture-pane -p -t firstmate:fm-task-x1 | grep -q '^WORKER-READY' && break; sleep 0.5; done
TASK_HEAD=$(git -C "$SLOT" rev-parse HEAD)
log "task commit on fm/task-x1: $TASK_HEAD"

# --- squash-merge the task, then main moves on -------------------------------
git clone -q "$LAB/origin.git" "$LAB/land"
echo feature > "$LAB/land/feature.txt"; git -C "$LAB/land" add -A
git -C "$LAB/land" -c user.email=t@t -c user.name=t commit -qm "squash: add feature (#1)"
echo other > "$LAB/land/other.txt"; git -C "$LAB/land" add -A
git -C "$LAB/land" -c user.email=t@t -c user.name=t commit -qm "another merged change"
git -C "$LAB/land" push -q origin main
git -C "$PROJ" fetch -q origin
log "origin/main after squash merge: $(git -C "$PROJ" rev-parse origin/main)"

# --- task record in the lab home -------------------------------------------
printf '%s\n' "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" "worktree=$SLOT" \
  "project=$PROJ" "kind=ship" "mode=no-mistakes" "spawn_gen=live-lab-task-x1" > "$LAB/state/task-x1.meta"
touch "$LAB/state/.last-watcher-beat"

PANE_PID=$(tm display-message -p -t firstmate:fm-task-x1 '#{pane_pid}')
HOLDER=$(pgrep -P "$PANE_PID" treehouse | head -1)
log "pane shell pid=$PANE_PID; treehouse holder pid=$HOLDER (cwd $(lsof -a -p "$HOLDER" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'))"
log "process tree under holder before teardown:"
ps -A -o pid=,ppid=,comm= | awk -v h="$HOLDER" '$2==h{print "  child of holder: " $0}' | tee -a "$OUT"

# Sample the holder's direct git children while teardown runs.
( while kill -0 "$HOLDER" 2>/dev/null; do
    ts=$(date +%H:%M:%S); ps -A -o pid=,ppid=,args= | awk -v h="$HOLDER" -v ts="$ts" '$2==h && $3 ~ /git$/ {print ts "  holder step: " $0}'
    sleep 0.3
  done; echo "$(date +%H:%M:%S)  holder $HOLDER exited" ) > "$LAB/steps.log" 2>&1 &
SAMPLER=$!

run_teardown() {  # <n>
  local n=$1
  rm -f "$LAB/rc"
  tm new-window -d -t firstmate -n "runner$n" -c "$WT_REPO" \
    "env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME='$LAB' PATH='$STUBS':\"\$PATH\" '$TREE/bin/fm-teardown.sh' task-x1 > '$LAB/out$n' 2> '$LAB/err$n'; echo \$? > '$LAB/rc'; sleep 30"
  for _ in $(seq 1 600); do [ -s "$LAB/rc" ] && break; sleep 0.5; done
  RC=$(cat "$LAB/rc" 2>/dev/null || echo timeout)
  log ""
  log "---- plain 'fm-teardown.sh task-x1' attempt $n: exit $RC ($(( SECONDS - T0 ))s since first attempt)"
  sed 's/^/  stderr| /' "$LAB/err$n" | tee -a "$OUT"
  sed 's/^/  stdout| /' "$LAB/out$n" | tee -a "$OUT"
}
T0=$SECONDS
run_teardown 1
sleep 2
if [ "$RC" != 0 ]; then
  log "  slot state after attempt 1: HEAD=$(git -C "$SLOT" rev-parse HEAD 2>/dev/null) branch=$(git -C "$SLOT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  log "  staged entries vs HEAD: $(git -C "$SLOT" diff --cached --name-status 2>/dev/null | tr '\n' ' ')"
  log "  git diff --quiet: $(git -C "$SLOT" diff --quiet && echo clean || echo dirty); index==origin/main: $(git -C "$SLOT" diff --cached --quiet origin/main && echo yes || echo no)"
  # wait for any holder to finish before a retry, like a captain would
  for _ in $(seq 1 60); do kill -0 "$HOLDER" 2>/dev/null || break; sleep 1; done
  run_teardown 2
fi
kill "$SAMPLER" 2>/dev/null; SAMPLER=
log ""
log "---- holder git steps observed during teardown:"
tee -a "$OUT" < "$LAB/steps.log" | sed -n '1,200p' >/dev/null
log ""
log "---- final state"
log "holder alive: $(kill -0 "$HOLDER" 2>/dev/null && echo yes || echo no)"
log "task window present: $(tm list-windows -t firstmate -F '#W' 2>/dev/null | grep -qx fm-task-x1 && echo yes || echo no)"
log "task meta present: $([ -e "$LAB/state/task-x1.meta" ] && echo yes || echo no)"
if [ -d "$SLOT" ]; then
  log "slot HEAD: $(git -C "$SLOT" rev-parse HEAD) (origin/main $(git -C "$SLOT" rev-parse origin/main)), branch: $(git -C "$SLOT" rev-parse --abbrev-ref HEAD)"
  log "slot porcelain entries: $(git -C "$SLOT" status --porcelain | wc -l | tr -d ' ')"
fi
log "local fm/task-x1 branch: $(git -C "$PROJ" rev-parse --verify -q refs/heads/fm/task-x1 || echo deleted)"
log "treehouse status:"
( cd "$PROJ" && TREEHOUSE_ROOT="$LAB/pool" treehouse status 2>&1 ) | sed 's/^/  /' | tee -a "$OUT"
