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
FIX=$1 BASE=$2 LABEL=$3 SLOW=${4:-2}; TREE=$FIX
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
tm send-keys -t firstmate:fm-task-x1 "git switch -q -c fm/task-x1 && echo feature > feature.txt && git add feature.txt ${WORKER_EXTRA:-} && git -c user.email=t@t -c user.name=t commit -qm 'add feature' && echo WORKER-READY && sleep 900" Enter
for _ in $(seq 1 60); do tm capture-pane -p -t firstmate:fm-task-x1 | grep -q '^WORKER-READY' && break; sleep 0.5; done
TASK_HEAD=$(git -C "$SLOT" rev-parse HEAD)
log "task commit on fm/task-x1: $TASK_HEAD"

# --- squash-merge the task, then main moves on -------------------------------
git clone -q "$LAB/origin.git" "$LAB/land"
[ "${LAND_FEATURE:-1}" = 0 ] || echo feature > "$LAB/land/feature.txt"; git -C "$LAB/land" add -A
git -C "$LAB/land" -c user.email=t@t -c user.name=t commit -qm "squash: add feature (#1)"
echo other > "$LAB/land/other.txt"; git -C "$LAB/land" add -A
git -C "$LAB/land" -c user.email=t@t -c user.name=t commit -qm "another merged change"
git -C "$LAB/land" push -q origin main
git -C "$PROJ" fetch -q origin
log "origin/main after squash merge: $(git -C "$PROJ" rev-parse origin/main)"

printf '%s\n' "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" "worktree=$SLOT" \
  "project=$PROJ" "kind=ship" "mode=no-mistakes" "spawn_gen=live-lab-task-x1" > "$LAB/state/task-x1.meta"
touch "$LAB/state/.last-watcher-beat"
PANE_PID=$(tm display-message -p -t firstmate:fm-task-x1 '#{pane_pid}')
HOLDER=$(pgrep -P "$PANE_PID" treehouse | head -1)
SUB=$(pgrep -P "$HOLDER" | head -1)
log "treehouse holder pid=$HOLDER (cwd $(lsof -a -p "$HOLDER" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')); worker subshell pid=$SUB"

N=0
run_td() {  # <tree> <tag>
  local tree=$1 tag=$2
  N=$((N+1)); rm -f "$LAB/rc"; local t0=$SECONDS
  tm new-window -d -t firstmate -n "runner$N" -c "$WT_REPO" \
    "env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME='$LAB' PATH='$STUBS':\"\$PATH\" '$tree/bin/fm-teardown.sh' task-x1 > '$LAB/out$N' 2> '$LAB/err$N'; echo \$? > '$LAB/rc'; sleep 30"
  for _ in $(seq 1 600); do [ -s "$LAB/rc" ] && break; sleep 0.5; done
  RC=$(cat "$LAB/rc" 2>/dev/null || echo timeout)
  log ""
  log "---- [$tag] plain 'fm-teardown.sh task-x1' attempt $N: exit $RC ($((SECONDS - t0))s)"
  grep -v '^fm-gate-refuse: gate agent lifecycle permitted' "$LAB/err$N" | sed 's/^/  stderr| /' | tee -a "$OUT"
  sed 's/^/  stdout| /' "$LAB/out$N" | grep -v 'Backlog:' | tee -a "$OUT"
}
slot_state() {
  log "  slot: HEAD=$(git -C "$SLOT" rev-parse --short HEAD) ($(git -C "$SLOT" rev-parse --abbrev-ref HEAD)); task commit=${TASK_HEAD:0:7}; origin/main=$(git -C "$SLOT" rev-parse --short origin/main)"
  log "  staged-vs-HEAD entries: $(git -C "$SLOT" diff --cached --name-status | tr '\n' ' ')| diff --quiet: $(git -C "$SLOT" diff --quiet && echo pass || echo fail) | index==origin/main: $(git -C "$SLOT" diff --cached --quiet origin/main && echo yes || echo no) | porcelain: $(git -C "$SLOT" status --porcelain | tr '\n' ';')"
  log "  treehouse status: $( (cd "$PROJ" && TREEHOUSE_ROOT="$LAB/pool" treehouse status 2>&1) | tail -1 | tr -s ' ')"
}

case "$LABEL" in
cut|cut-unlanded)
  # Trigger the holder's own return the way the reaper does (end the worker
  # subshell), then SIGKILL only its `git clean -fd` step, as the old reaper did.
  log "killing worker subshell $SUB (as the reaper does) and waiting for the holder's clean step"
  pkill -KILL -P "$SUB" 2>/dev/null; kill -KILL "$SUB"
  CLEAN=
  for _ in $(seq 1 200); do
    CLEAN=$(ps -A -o pid=,ppid=,args= | awk -v h="$HOLDER" '$2==h && $0 ~ /git clean/ {print $1}' | head -1)
    [ -n "$CLEAN" ] && break; sleep 0.1
  done
  log "holder clean step pid=$CLEAN: $(ps -o args= -p "$CLEAN")"
  kill -KILL "$CLEAN"
  for _ in $(seq 1 50); do kill -0 "$HOLDER" 2>/dev/null || break; sleep 0.2; done
  log "holder alive after its step was cut: $(kill -0 "$HOLDER" 2>/dev/null && echo yes || echo no)"
  log "pane after the cut:"; tm capture-pane -p -t firstmate:fm-task-x1 | grep -v '^$' | tail -4 | sed 's/^/  pane| /' | tee -a "$OUT"
  log "== persistent interrupted-reset state:"
  slot_state
  if [ "$LABEL" = cut-unlanded ]; then
    log "  task commit landed on origin/main? content check: $(git -C "$SLOT" cat-file -e origin/main:feature.txt 2>/dev/null && echo yes || echo 'no (feature.txt absent from origin/main)')"
    run_td "$FIX" "fix, unlanded task commit"; slot_state
    log "  task commit still reachable: $(git -C "$PROJ" cat-file -t "$TASK_HEAD")"
    run_td "$FIX" "fix retry, unlanded task commit"
    TREE_DONE=1
  else
  run_td "$BASE" "base a256cb5"; slot_state
  run_td "$BASE" "base a256cb5 retry"; slot_state
  fi
  if [ -z "${TREE_DONE:-}" ]; then
  log ""; log "== adversarial: same shape plus an untracked file hidden by status.showUntrackedFiles=no"
  git -C "$SLOT" config status.showUntrackedFiles no
  echo "precious" > "$SLOT/notes.txt"
  run_td "$FIX" "fix"; slot_state
  log "  notes.txt still present: $([ -f "$SLOT/notes.txt" ] && cat "$SLOT/notes.txt" || echo MISSING)"
  log ""; log "== adversarial: same shape plus a tracked-file edit"
  git -C "$SLOT" config --unset status.showUntrackedFiles; rm -f "$SLOT/notes.txt"
  echo edited >> "$SLOT/other.txt"
  run_td "$FIX" "fix"; slot_state
  log "  other.txt edit still present: $(tail -1 "$SLOT/other.txt")"
  git -C "$SLOT" checkout -q -- other.txt
  log ""; log "== genuine interrupted-reset state only"
  slot_state
  run_td "$FIX" "fix"
  fi
  ;;
idle)
  log "worker left firstmate-ignorable untracked file(s): $WORKER_EXTRA"
  ( while kill -0 "$HOLDER" 2>/dev/null; do sleep 0.2; done; echo "$(date +%H:%M:%S) holder exited" > "$LAB/holder-exit" ) &
  ( prev=; while tm has-session -t firstmate 2>/dev/null; do
      cur=$(tm capture-pane -p -t firstmate:fm-task-x1 2>/dev/null | grep -v '^$' | tail -3)
      [ -n "$cur" ] && [ "$cur" != "$prev" ] && { printf '%s pane:\n%s\n' "$(date +%H:%M:%S)" "$cur" | sed 's/^/  /'; prev=$cur; }
      ps -A -o pid=,ppid=,args= | awk -v h="$HOLDER" -v ts="$(date +%H:%M:%S)" '$2==h && $3 ~ /git$/ {print "  " ts " holder step: " $3 " " $4 " " $5}'
      sleep 0.3; done ) > "$LAB/pane.log" 2>&1 &
  PANESAMP=$!
  log "teardown start: $(date +%H:%M:%S)"
  run_td "$FIX" "fix"
  log "teardown end: $(date +%H:%M:%S); $(cat "$LAB/holder-exit" 2>/dev/null || echo 'holder still alive')"
  kill "$PANESAMP" 2>/dev/null; log "task pane and holder steps during teardown:"; uniq < "$LAB/pane.log" | tee -a "$OUT"
  ;;
esac
log ""; log "---- final state"
log "task window present: $(tm list-windows -t firstmate -F '#W' 2>/dev/null | grep -qx fm-task-x1 && echo yes || echo no)"
log "task meta present: $([ -e "$LAB/state/task-x1.meta" ] && echo yes || echo no)"
[ -d "$SLOT" ] && slot_state
