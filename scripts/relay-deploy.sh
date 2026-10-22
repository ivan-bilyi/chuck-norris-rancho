#!/usr/bin/env bash
# relay-deploy — build Relay from a git revision and deploy it on this host.
#
# Run it ON the host (Rancho), from the repo clone there. It:
#   1. fetches the repo (remote-tracking refs only; the clone's work tree is
#      not touched) and exports relay/ at the target SHA into a fresh build dir
#      outside the live tree;
#   2. runs npm ci + npm run build there with the node binary the launchd
#      service runs, and checks that the dependencies (native ones included)
#      load under that node;
#   3. stages the build in <live>.next (built up in <live>.next.partial and
#      renamed when complete; the live tree and <live>.prev are not touched
#      yet), then waits until Relay has no claude child process;
#   4. re-checks that nothing is in flight and, from here on ignoring
#      HUP/INT/TERM/PIPE, swaps only the CODE items (CODE_ITEMS below) of the
#      live tree; the code that was live becomes <live>.prev, the rollback
#      target, unless it is the same commit or never passed a smoke test (then
#      the existing <live>.prev stays the rollback target);
#   5. restarts the service with launchctl kickstart (or loads it with
#      launchctl bootstrap when it is not loaded) and smoke-tests it: new pid
#      running, "Relay online as" (Discord ready) and "Reconcile scheduler
#      started" in the log, GET /healthz = 200 on the notify port, pid stable.
#      A fatal start error in the error log fails it at once. If it fails, the
#      previous code is swapped back and restarted, and <live>.prev is put
#      back as it was;
#   6. runs a one-line claude auth probe with Relay's token (with a timeout).
#
# Interruptions: before step 4 an interrupted run changes nothing live (a
# staged <live>.next is removed). During steps 4-5 signals are ignored and
# output errors are tolerated, so a dropped SSH session or Ctrl-C cannot
# leave a half-done deploy: the run finishes the swap, smoke test and any
# revert. Use --detach to run it in the background with its own log.
#
# State in the live tree (.env*, relay.db*, logs/ and anything else that is
# not a CODE item) is never moved or written. The script reads only the
# service logs and two settings from .env: RELAY_NOTIFY_PORT and, for the auth
# probe, CLAUDE_CODE_OAUTH_TOKEN (passed to claude in its environment, never
# printed).
#
# Each code set records itself in <set>/REVISION as key=value lines:
#   sha=<40-hex commit>   ref=<requested rev>   subject=<commit subject>
#   deployed_at=<UTC ISO-8601>   node=<node version>
#   status=staged|ok|failed   (ok = passed its smoke test)
# REVISION is a CODE item, so it moves with its code: <live>/REVISION always
# names what runs. No REVISION means code that was live before this script
# existed; it counts as a valid rollback target.
#
# Deploying the commit that is already live with status ok changes nothing:
# the run says "already live", runs the auth probe and exits 0 (or 3).
# --force rebuilds and restarts it anyway, keeping <live>.prev as it is.
#
# Usage:
#   scripts/relay-deploy.sh [--sha <rev>] [--dry-run] [--build-only] [--detach]
#                           [--force] [--no-fetch] [--no-wait] [--no-auth-probe]
#   scripts/relay-deploy.sh --rollback [--dry-run] [--detach] [--no-wait]
#
#   --sha <rev>      what to deploy (default: <remote>/main, after a fetch)
#   --dry-run        print the plan and the current state; change nothing
#   --build-only     fetch + build + load check only; no swap, no restart
#   --detach         run in the background (nohup), safe to disconnect; the
#                    output goes to <build root>/last-run.log, whose last line
#                    is "relay-deploy: finished: exit <code>"
#   --force          rebuild and restart even if the target is already live
#   --no-fetch       use the refs already in the clone
#   --no-wait        do not wait for in-flight claude turns (they are killed)
#   --no-auth-probe  skip the claude auth probe
#   --rollback       swap the live code and <live>.prev, then restart and
#                    smoke-test (running it twice returns to where you were).
#                    Refuses code whose status is not ok. If the rollback
#                    target fails, the code you had is swapped back in.
#
# Exit codes:
#   0 deployed / rolled back / already live (or dry run / build ok)
#   1 failed or interrupted before anything live changed (any git/npm/build
#     failure maps here)
#   2 usage
#   3 deployed, but the auth probe failed or timed out (code stays: rolling
#     back would not fix auth)
#   4 smoke test failed; the code that was live before is live again and
#     <live>.prev is as it was
#   5 smoke test failed and the previous code did not come up either; the
#     cause is likely outside the code (network, DNS, Discord, .env): the
#     message lists what to check
#   6 the swap itself failed midway (filesystem error); inspect the dirs named
#
# Settings (environment; defaults come from the launchd plist and $HOME):
#   RELAY_LABEL               launchd label             (com.rancho.relay)
#   RELAY_PLIST               plist of that label       (~/Library/LaunchAgents/<label>.plist)
#   RELAY_HOME                live tree                 (plist WorkingDirectory)
#   RELAY_PREV                previous code             (<live>.prev)
#   RELAY_REPO                git clone to build from   (the repo holding this script)
#   RELAY_REMOTE              remote to fetch           (origin)
#   RELAY_BUILD_ROOT          builds, lock, logs        (${XDG_CACHE_HOME:-~/.cache}/relay-deploy)
#   RELAY_NOTIFY_PORT         healthz port              (.env RELAY_NOTIFY_PORT, else 4466)
#   RELAY_IDLE_TIMEOUT        seconds to wait for idle  (900)
#   RELAY_SMOKE_TIMEOUT       seconds for the ready checks (90)
#   RELAY_SMOKE_SETTLE        seconds the new pid must stay up (10)
#   RELAY_AUTH_PROBE_TIMEOUT  seconds for the auth probe (120)
set -euo pipefail
ORIG_ARGS=("$@")

# Code items of a code set: everything a build produces, nothing else.
# The first five are what the service runs; the rest are the matching sources
# so the live tree never shows code that differs from what runs.
CODE_ITEMS="dist node_modules package.json package-lock.json REVISION src tsconfig.json CLAUDE.md relay.env.example templates"
REQUIRED_BUILD_ITEMS="dist node_modules package.json package-lock.json"
OWNED=".relay-deploy-owned"      # marks <live>.next / <live>.prev as made by this script

PHASE=none        # none | prepare | critical | probe : what an exit at this point means
RUN_LOG=""        # foreground real runs copy their lines here
TEE=1
say() {
  local line="relay-deploy: $*"
  printf '%s\n' "$line" 2>/dev/null || true
  if [ -n "$RUN_LOG" ] && [ "$TEE" = 1 ]; then printf '%s\n' "$line" >> "$RUN_LOG" 2>/dev/null || true; fi
}
die() {
  local line="relay-deploy: ERROR: $1"
  printf '%s\n' "$line" >&2 2>/dev/null || true
  if [ -n "$RUN_LOG" ] && [ "$TEE" = 1 ]; then printf '%s\n' "$line" >> "$RUN_LOG" 2>/dev/null || true; fi
  exit "${2:-1}"
}

# ── arguments ──────────────────────────────────────────────────
REV=""; DRY_RUN=0; BUILD_ONLY=0; FETCH=1; WAIT_IDLE=1; AUTH_PROBE=1; ROLLBACK=0; DETACH=0; FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sha) [ $# -ge 2 ] || die "--sha needs a revision" 2; REV="$2"; shift 2 ;;
    --sha=*) REV="${1#--sha=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --build-only) BUILD_ONLY=1; shift ;;
    --detach) DETACH=1; shift ;;
    --force) FORCE=1; shift ;;
    --no-fetch) FETCH=0; shift ;;
    --no-wait) WAIT_IDLE=0; shift ;;
    --no-auth-probe) AUTH_PROBE=0; shift ;;
    --rollback) ROLLBACK=1; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" 2 ;;
  esac
done
if [ "$ROLLBACK" = 1 ] && { [ -n "$REV" ] || [ "$BUILD_ONLY" = 1 ] || [ "$FORCE" = 1 ]; }; then
  die "--rollback takes no --sha/--build-only/--force" 2
fi
if [ "$DETACH" = 1 ] && [ "$DRY_RUN" = 1 ]; then die "--detach makes no sense with --dry-run" 2; fi

# ── configuration ──────────────────────────────────────────────
UID_N="$(id -u)"
LABEL="${RELAY_LABEL:-com.rancho.relay}"
SERVICE="gui/$UID_N/$LABEL"
PLIST="${RELAY_PLIST:-$HOME/Library/LaunchAgents/$LABEL.plist}"
[ -f "$PLIST" ] || die "launchd plist not found: $PLIST"

plist_get() { plutil -extract "$1" raw -o - "$PLIST" 2>/dev/null || true; }

NODE="$(plist_get ProgramArguments.0)"
ENTRY="$(plist_get ProgramArguments.1)"
RELAY_HOME="${RELAY_HOME:-$(plist_get WorkingDirectory)}"
RELAY_HOME="${RELAY_HOME:-$HOME/relay}"
RELAY_PREV="${RELAY_PREV:-$RELAY_HOME.prev}"
RELAY_PREV_OLD="$RELAY_PREV.old"
RELAY_NEXT="$RELAY_HOME.next"
RELAY_NEXT_PARTIAL="$RELAY_NEXT.partial"
SWAP_TMP="$RELAY_HOME.swap"
LOG="$(plist_get StandardOutPath)"
ERR_LOG="$(plist_get StandardErrorPath)"
SERVICE_PATH="$(plist_get EnvironmentVariables.PATH)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELAY_REPO="${RELAY_REPO:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$HOME/chuck-norris-rancho")}"
REMOTE="${RELAY_REMOTE:-origin}"
BUILD_ROOT="${RELAY_BUILD_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/relay-deploy}"
LOCK="$BUILD_ROOT/lock"
IDLE_TIMEOUT="${RELAY_IDLE_TIMEOUT:-900}"
SMOKE_TIMEOUT="${RELAY_SMOKE_TIMEOUT:-90}"
SMOKE_SETTLE="${RELAY_SMOKE_SETTLE:-10}"
PROBE_TIMEOUT="${RELAY_AUTH_PROBE_TIMEOUT:-120}"

[ -n "$NODE" ] && [ -x "$NODE" ] || die "node from $PLIST ProgramArguments.0 is not executable: '$NODE'"
NODE_DIR="$(dirname "$NODE")"
BUILD_PATH="$NODE_DIR:${SERVICE_PATH:-}:$PATH"     # node of the service first (native ABI)
PROBE_PATH="${SERVICE_PATH:-}:$PATH"                # what Relay's own spawns resolve claude from
NPM="$NODE_DIR/npm"
[ -x "$NPM" ] || NPM="$(PATH="$BUILD_PATH" command -v npm || true)"
[ -n "$NPM" ] || die "npm not found next to $NODE or on the service PATH"
[ "$ENTRY" = "$RELAY_HOME/dist/index.js" ] \
  || die "plist runs '$ENTRY', expected '$RELAY_HOME/dist/index.js'; layout differs, refusing"
[ -d "$RELAY_HOME" ] || die "live tree not found: $RELAY_HOME"
case "$RELAY_PREV" in
  ""|/|"$HOME"|"$HOME/"|"$RELAY_HOME"|"$RELAY_HOME/") die "refusing RELAY_PREV='$RELAY_PREV'" ;;
esac
[ -f "$RELAY_HOME/.env" ] || die "$RELAY_HOME/.env missing; Relay cannot start without it"

# One non-secret setting from .env, without printing anything else.
env_setting() { sed -n "s/^$1=//p" "$RELAY_HOME/.env" | tail -n 1 | sed "s/^[\"']//; s/[\"']\$//"; }
NOTIFY_PORT="${RELAY_NOTIFY_PORT:-$(env_setting RELAY_NOTIFY_PORT)}"
NOTIFY_PORT="${NOTIFY_PORT:-4466}"

# ── helpers ────────────────────────────────────────────────────
service_field() { { launchctl print "$SERVICE" 2>/dev/null || true; } | awk -v k="$1" '$1 == k && $2 == "=" { print $3; exit }'; }
service_pid() { service_field pid; }
service_state() { service_field state; }
claude_children() { { pgrep -P "$1" -f claude 2>/dev/null || true; } | wc -l | tr -d ' '; }
file_size() { if [ -n "$1" ] && [ -f "$1" ]; then stat -f %z "$1"; else echo 0; fi; }

revision_of() {
  local sha=""
  [ -f "$1/REVISION" ] && sha="$(awk '/^sha=/ { print substr($0, 5); exit }' "$1/REVISION")"
  echo "${sha:-unrecorded}"
}
# revision_of, readable in messages
rev_label() {
  local r; r="$(revision_of "$1")"
  if [ "$r" = unrecorded ]; then echo "the code from before this script"; else echo "$r"; fi
}
# ok | staged | failed | unknown, or "unrecorded" for code without REVISION
# (live before this script existed).
status_of() {
  local s=""
  [ -f "$1/REVISION" ] || { echo unrecorded; return 0; }
  s="$(awk '/^status=/ { s = substr($0, 8) } END { print s }' "$1/REVISION")"
  echo "${s:-unknown}"
}
set_status() {   # rewrite the status line of <dir>/REVISION by an atomic rename
  local f="$1/REVISION"
  { if [ -f "$f" ]; then grep -v '^status=' "$f" || true; fi; echo "status=$2"; } > "$f.tmp"
  mv "$f.tmp" "$f"
}
rollbackable() { case "$(status_of "$1")" in ok|unrecorded) return 0 ;; *) return 1 ;; esac; }

present_items() {
  local dir="$1" out="" item
  for item in $CODE_ITEMS; do
    if [ -e "$dir/$item" ] || [ -L "$dir/$item" ]; then out="$out $item"; fi
  done
  echo "${out# }"
}

untouched_items() {
  local out="" entry name item code
  for entry in "$RELAY_HOME"/* "$RELAY_HOME"/.[!.]*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name="$(basename "$entry")"; code=0
    for item in $CODE_ITEMS; do [ "$name" = "$item" ] && code=1; done
    [ "$code" = 1 ] || out="$out $name"
  done
  echo "${out# }"
}

# Exchange the code items of the live tree and another code set dir (a rename
# per item, through a sibling temp dir). Nothing is deleted.
swap_code() {
  local other="$1" item
  [ ! -e "$SWAP_TMP" ] || die "$SWAP_TMP appeared during the run; inspect it" 6
  mkdir "$SWAP_TMP" || die "cannot create $SWAP_TMP" 6
  for item in $CODE_ITEMS; do
    if [ -e "$RELAY_HOME/$item" ] || [ -L "$RELAY_HOME/$item" ]; then
      mv "$RELAY_HOME/$item" "$SWAP_TMP/$item" || die "swap failed moving $RELAY_HOME/$item; code is split between $RELAY_HOME, $SWAP_TMP and $other" 6
    fi
  done
  for item in $CODE_ITEMS; do
    if [ -e "$other/$item" ] || [ -L "$other/$item" ]; then
      mv "$other/$item" "$RELAY_HOME/$item" || die "swap failed moving $other/$item; code is split between $RELAY_HOME, $SWAP_TMP and $other" 6
    fi
  done
  for item in $CODE_ITEMS; do
    if [ -e "$SWAP_TMP/$item" ] || [ -L "$SWAP_TMP/$item" ]; then
      mv "$SWAP_TMP/$item" "$other/$item" || die "swap failed moving $SWAP_TMP/$item; code is split between $RELAY_HOME, $SWAP_TMP and $other" 6
    fi
  done
  rmdir "$SWAP_TMP" || die "cannot remove $SWAP_TMP after the swap" 6
}

# Move a script-owned dir out of the way by rename (instant), then delete it.
discard_dir() {
  local d="$1" trash
  [ -e "$d" ] || return 0
  mkdir -p "$BUILD_ROOT"
  trash="$BUILD_ROOT/discard-$$-$(date +%s)"
  mv "$d" "$trash" && rm -rf "$trash"
}

# Leftovers of an interrupted earlier run. Everything here runs before this
# run changes anything; nothing that may hold live-proven code is deleted.
check_layout() {
  local problems=0
  if [ -e "$SWAP_TMP" ]; then
    say "found $SWAP_TMP: an earlier swap was cut off; its items belong to $RELAY_HOME or to the dir it was swapping with"
    problems=1
  fi
  if [ -e "$RELAY_PREV" ] && [ ! -f "$RELAY_PREV/$OWNED" ]; then
    say "found $RELAY_PREV that this script did not make; move it away"
    problems=1
  fi
  if [ -e "$RELAY_PREV_OLD" ]; then
    if [ -f "$RELAY_PREV/$OWNED" ]; then
      # An older rollback target kept while a deploy ran; <live>.prev is the
      # newer one and stays.
      if [ "$DRY_RUN" = 1 ]; then say "would remove $RELAY_PREV_OLD (an older rollback target left by an interrupted deploy; $RELAY_PREV stays)"
      else say "removing $RELAY_PREV_OLD (an older rollback target left by an interrupted deploy; $RELAY_PREV stays)"; discard_dir "$RELAY_PREV_OLD"; fi
    elif [ ! -e "$RELAY_PREV" ] && [ ! -e "$RELAY_NEXT" ]; then
      # Cut off just before the older rollback target was put back: put it back.
      if [ "$DRY_RUN" = 1 ]; then say "would rename $RELAY_PREV_OLD back to $RELAY_PREV (an interrupted deploy had not put it back yet)"
      else say "renaming $RELAY_PREV_OLD back to $RELAY_PREV (an interrupted deploy had not put it back yet)"; mv "$RELAY_PREV_OLD" "$RELAY_PREV"; fi
    else
      say "found $RELAY_PREV_OLD (an older rollback target) but no $RELAY_PREV: an earlier deploy was killed between the swap and keeping the code that was live ($RELAY_NEXT)"
      say "  to keep the code that was live as the rollback target: mv $RELAY_NEXT $RELAY_PREV && rm -rf $RELAY_PREV_OLD"
      say "  to keep the older one instead: mv $RELAY_PREV_OLD $RELAY_PREV && rm -rf $RELAY_NEXT"
      problems=1
    fi
  fi
  if [ -e "$RELAY_NEXT_PARTIAL" ]; then
    if [ "$DRY_RUN" = 1 ]; then say "would remove $RELAY_NEXT_PARTIAL (staging that was cut off; it never went live)"
    else say "removing $RELAY_NEXT_PARTIAL (staging that was cut off; it never went live)"; discard_dir "$RELAY_NEXT_PARTIAL"; fi
  fi
  if [ -e "$RELAY_NEXT" ] && [ ! -e "$RELAY_PREV_OLD" ]; then
    if [ -f "$RELAY_NEXT/$OWNED" ] && [ "$(status_of "$RELAY_NEXT")" = staged ]; then
      if [ "$DRY_RUN" = 1 ]; then say "would remove $RELAY_NEXT (a staged build that never went live)"
      else say "removing $RELAY_NEXT (a staged build that never went live)"; discard_dir "$RELAY_NEXT"; fi
    else
      say "found $RELAY_NEXT holding the code that was live before an earlier deploy (revision $(revision_of "$RELAY_NEXT"), status $(status_of "$RELAY_NEXT")); that deploy was killed right after its swap"
      say "  live now: $(revision_of "$RELAY_HOME") (status $(status_of "$RELAY_HOME")); rollback target: $( [ -e "$RELAY_PREV" ] && echo "$(revision_of "$RELAY_PREV") (status $(status_of "$RELAY_PREV"))" || echo none)"
      say "  to make it the rollback target: rm -rf $RELAY_PREV && mv $RELAY_NEXT $RELAY_PREV; to drop it: rm -rf $RELAY_NEXT"
      problems=1
    fi
  fi
  return "$problems"
}

# Text appended to a file after byte offset $2.
log_since() {
  local f="$1" from="$2" size
  [ -n "$f" ] && [ -f "$f" ] || return 0
  size="$(file_size "$f")"
  [ "$size" -ge "$from" ] || from=0   # rotated meanwhile
  tail -c "+$((from + 1))" "$f" 2>/dev/null || true
}
show_lines() {   # show_lines <label> <text>: the last 5 lines, indented
  local line
  [ -n "$2" ] || return 0
  say "$1:"
  printf '%s\n' "$2" | tail -n 5 | while IFS= read -r line; do say "    $line"; done
}

smoke() {
  local old_pid="$1" from="$2" efrom="$3" deadline pid="" p out err
  deadline=$(( $(date +%s) + SMOKE_TIMEOUT ))
  while :; do
    pid="$(service_pid)"
    if [ -n "$pid" ] && [ "$pid" != "$old_pid" ] && [ "$(service_state)" = "running" ]; then break; fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      say "smoke: service did not come up with a new pid"; show_lines "new lines in $ERR_LOG" "$(log_since "$ERR_LOG" "$efrom")"; return 1
    fi
    sleep 1
  done
  say "smoke: running, pid $pid"
  while :; do
    err="$(log_since "$ERR_LOG" "$efrom")"
    case "$err" in *"Failed to start bot"*|*"DISCORD_BOT_TOKEN is required"*)
      say "smoke: Relay reports a fatal start error"; show_lines "new lines in $ERR_LOG" "$err"; return 1 ;;
    esac
    p="$(service_pid)"
    if [ "$p" != "$pid" ]; then
      say "smoke: the new process went away (pid $pid -> ${p:-none})"; show_lines "new lines in $ERR_LOG" "$err"; return 1
    fi
    out="$(log_since "$LOG" "$from")"
    case "$out" in *"Relay online as"*)
      case "$out" in *"Reconcile scheduler started"*) break ;; esac ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
      say "smoke: no 'Relay online as' + 'Reconcile scheduler started' in $LOG within ${SMOKE_TIMEOUT}s"
      show_lines "new lines in $ERR_LOG" "$err"; return 1
    fi
    sleep 1
  done
  say "smoke: Discord ready, reconcile scheduler started"
  while ! curl -fsS -m 3 "http://127.0.0.1:$NOTIFY_PORT/healthz" >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] || { say "smoke: GET 127.0.0.1:$NOTIFY_PORT/healthz failed"; return 1; }
    sleep 1
  done
  say "smoke: healthz ok on 127.0.0.1:$NOTIFY_PORT"
  sleep "$SMOKE_SETTLE"
  if [ "$(service_pid)" != "$pid" ] || [ "$(service_state)" != "running" ]; then
    say "smoke: pid changed or service stopped within ${SMOKE_SETTLE}s (crash loop?)"
    show_lines "new lines in $ERR_LOG" "$(log_since "$ERR_LOG" "$efrom")"; return 1
  fi
  say "smoke: pid $pid stable for ${SMOKE_SETTLE}s"
}

restart_and_smoke() {
  local old_pid from efrom
  old_pid="$(service_pid)"; from="$(file_size "$LOG")"; efrom="$(file_size "$ERR_LOG")"
  if launchctl print "$SERVICE" >/dev/null 2>&1; then
    say "restart: launchctl kickstart -k $SERVICE"
    launchctl kickstart -k "$SERVICE" || say "launchctl kickstart returned an error"
  else
    say "start: launchctl bootstrap gui/$UID_N $PLIST (the service was not loaded)"
    launchctl bootstrap "gui/$UID_N" "$PLIST" || say "launchctl bootstrap returned an error"
  fi
  smoke "$old_pid" "$from" "$efrom"
}

# After a swap that put the target code live and the other code in
# <live>.prev: restart and smoke-test. On failure swap back and restart again.
# The target is marked failed only when the other code then comes up (so the
# failure is the target's). Returns 0 (live), 4 (reverted), 5 (revert failed).
activate() {
  if restart_and_smoke; then
    if [ -f "$RELAY_HOME/REVISION" ]; then set_status "$RELAY_HOME" ok; fi
    return 0
  fi
  if [ ! -f "$RELAY_PREV/$OWNED" ]; then say "smoke test failed and there is no previous code to go back to"; return 5; fi
  say "smoke test failed: swapping the code back"
  swap_code "$RELAY_PREV"
  if restart_and_smoke; then set_status "$RELAY_PREV" failed; return 4; fi
  return 5
}

# Run "$@" with a time limit (no `timeout` on macOS). Returns the command's
# status, 143/137 when it was killed.
with_timeout() {
  local secs="$1" pid watcher rc=0
  shift
  "$@" &
  pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null && sleep 3 && kill -KILL "$pid" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
  watcher=$!
  wait "$pid" || rc=$?
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  return "$rc"
}

# One cheap claude turn with Relay's own token: proves the subscription auth
# that every spawned session uses. Runs in a fixed scratch dir with no MCP
# servers and no saved session.
auth_probe() {
  local claude_bin dir out rc=0
  claude_bin="$(PATH="$PROBE_PATH" command -v claude || true)"
  [ -n "$claude_bin" ] || { say "auth probe: claude not found on the service PATH"; return 1; }
  dir="$BUILD_ROOT/auth-probe"; mkdir -p "$dir"
  out="$(
    cd "$dir"
    token="$(env_setting CLAUDE_CODE_OAUTH_TOKEN)"
    if [ -n "$token" ]; then export CLAUDE_CODE_OAUTH_TOKEN="$token"; fi
    export PATH="$PROBE_PATH"
    with_timeout "$PROBE_TIMEOUT" "$claude_bin" -p "Reply with just: OK" --output-format json \
      --no-session-persistence --strict-mcp-config --model haiku </dev/null 2>&1
  )" || rc=$?
  case "$out" in *'"is_error":false'*) say "auth probe: ok"; return 0 ;; esac
  if [ "$rc" -ge 128 ]; then say "auth probe: FAILED: no answer within ${PROBE_TIMEOUT}s"; return 1; fi
  say "auth probe: FAILED: $(printf '%s' "$out" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).result)}catch{console.log(s.slice(0,300))}})')"
  return 1
}

wait_idle() {
  local pid n deadline
  [ "$WAIT_IDLE" = 1 ] || return 0
  pid="$(service_pid)"; [ -n "$pid" ] || return 0
  deadline=$(( $(date +%s) + IDLE_TIMEOUT ))
  while n="$(claude_children "$pid")"; [ "$n" != "0" ]; do
    [ "$(date +%s)" -lt "$deadline" ] || die "Relay still has $n claude turn(s) in flight after ${IDLE_TIMEOUT}s; nothing live changed"
    say "waiting: $n claude turn(s) in flight"
    sleep 5
  done
}

# Wait for idle, then stop reacting to HUP/INT/TERM and re-check idle right
# before the swap: from here to the end of the smoke test (and any revert)
# the run must finish.
enter_critical() {
  local pid
  [ "$WAIT_IDLE" = 1 ] || say "not waiting for in-flight turns (--no-wait): they are killed by the restart"
  while :; do
    wait_idle
    trap '' HUP INT TERM
    PHASE=critical
    [ "$WAIT_IDLE" = 1 ] || return 0
    pid="$(service_pid)"
    if [ -z "$pid" ] || [ "$(claude_children "$pid")" = 0 ]; then return 0; fi
    PHASE=prepare
    trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
    say "a claude turn started meanwhile; waiting again"
  done
}
leave_critical() {
  PHASE=probe
  trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
}

LOCK_HELD=0
acquire_lock() {
  local holder
  mkdir -p "$BUILD_ROOT"
  if ! mkdir "$LOCK" 2>/dev/null; then
    holder="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
      die "another deploy (pid $holder) is running; see $BUILD_ROOT/last-run.log"
    fi
    say "removing a stale lock (pid ${holder:-unknown} is gone)"
    rm -rf "$LOCK"; mkdir "$LOCK" || die "cannot take the lock $LOCK"
  fi
  echo "$$" > "$LOCK/pid"
  LOCK_HELD=1
}

SUMMARY=""; STAGED_NEXT=0; BUILD=""
on_exit() {
  local rc=$?
  trap '' HUP INT TERM
  if [ "$PHASE" != none ]; then
    case "$PHASE:$rc" in
      prepare:0|prepare:1|prepare:2) ;;
      prepare:*) say "stopped (exit $rc) before anything live changed"; rc=1 ;;
      critical:0|critical:3|critical:4|critical:5|critical:6) ;;
      critical:*) say "unexpected exit $rc during the swap or restart: check $RELAY_HOME, $RELAY_PREV, $RELAY_NEXT, $SWAP_TMP"; rc=6 ;;
      probe:0|probe:3|probe:4|probe:5) ;;
      probe:*) say "deployed; the auth probe did not complete (exit $rc)"; rc=3 ;;
    esac
    if [ "$PHASE" = prepare ] && [ "$STAGED_NEXT" = 1 ]; then
      discard_dir "$RELAY_NEXT_PARTIAL" || true; discard_dir "$RELAY_NEXT" || true
    fi
    if [ -n "$BUILD" ] && [ "$BUILD_ONLY" = 0 ]; then rm -rf "$BUILD" || true; fi
    mkdir -p "$BUILD_ROOT" 2>/dev/null || true
    printf '%s exit %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" "$SUMMARY" >> "$BUILD_ROOT/history.log" 2>/dev/null || true
    say "finished: exit $rc"
  fi
  if [ "$LOCK_HELD" = 1 ]; then rm -rf "$LOCK" 2>/dev/null || true; fi
  exit "$rc"
}

# Start of a real (non-dry) run: lock, own log, signal handling.
begin_run() {
  trap '' PIPE                  # a closed stdout must not kill the run
  trap on_exit EXIT
  trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
  acquire_lock
  PHASE=prepare
  RUN_LOG="$BUILD_ROOT/last-run.log"
  if [ "${RELAY_DEPLOY_DETACHED:-0}" = 1 ]; then TEE=0; else : > "$RUN_LOG"; fi
  say "started $(date -u +%Y-%m-%dT%H:%M:%SZ) pid $$: ${ORIG_ARGS[*]+${ORIG_ARGS[*]}}"
}

down_checklist() {
  say "Relay did not come up with either code. That usually means the cause is outside the code. Check, in order:"
  say "  1. network and DNS: curl -sS -m 5 -o /dev/null -w '%{http_code}\\n' https://discord.com/api/v10/gateway   (expect 200)"
  say "  2. the service: launchctl print $SERVICE | grep -E 'state|pid|last exit'"
  say "  3. the newest lines of $ERR_LOG and $LOG"
  say "  4. $RELAY_HOME/.env exists and sets DISCORD_BOT_TOKEN: grep -c '^DISCORD_BOT_TOKEN=' $RELAY_HOME/.env   (expect 1)"
  say "  Live now: $(revision_of "$RELAY_HOME") (status $(status_of "$RELAY_HOME")); previous: $(revision_of "$RELAY_PREV")."
  say "  After fixing the cause: launchctl kickstart -k $SERVICE; then re-run the deploy."
}

# ── detach ─────────────────────────────────────────────────────
if [ "$DETACH" = 1 ] && [ "${RELAY_DEPLOY_DETACHED:-0}" != 1 ]; then
  mkdir -p "$BUILD_ROOT"
  holder="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then die "another deploy (pid $holder) is running; see $BUILD_ROOT/last-run.log"; fi
  RELAY_DEPLOY_DETACHED=1 nohup "${BASH:-bash}" "$0" "${ORIG_ARGS[@]}" > "$BUILD_ROOT/last-run.log" 2>&1 < /dev/null &
  say "running in the background as pid $!; safe to disconnect"
  say "follow: tail -f $BUILD_ROOT/last-run.log   (done when it shows 'relay-deploy: finished: exit <code>')"
  exit 0
fi

# ── rollback ───────────────────────────────────────────────────
if [ "$ROLLBACK" = 1 ]; then
  if [ "$DRY_RUN" = 0 ]; then begin_run; fi
  check_layout || die "earlier run left the layout unfinished (see above); nothing changed"
  [ -f "$RELAY_PREV/$OWNED" ] || die "no previous code at $RELAY_PREV"
  rollbackable "$RELAY_PREV" \
    || die "the code in $RELAY_PREV has status '$(status_of "$RELAY_PREV")' (it never passed a smoke test); not rolling back to it"
  TO_REV="$(revision_of "$RELAY_PREV")"; FROM_REV="$(revision_of "$RELAY_HOME")"
  SUMMARY="rollback $FROM_REV -> $TO_REV"
  say "live:     $RELAY_HOME (revision $FROM_REV, status $(status_of "$RELAY_HOME"))"
  say "previous: $RELAY_PREV (revision $TO_REV, status $(status_of "$RELAY_PREV")): $(present_items "$RELAY_PREV")"
  if [ "$DRY_RUN" = 1 ]; then
    say "dry run: would wait for idle, swap those items with the live ones, restart and smoke-test; nothing changed"
    exit 0
  fi
  enter_critical
  swap_code "$RELAY_PREV"
  say "swapped: live revision is now $TO_REV"
  rc=0; activate || rc=$?
  leave_critical
  case "$rc" in
    0) say "rollback done; run --rollback again to return to $FROM_REV"; exit 0 ;;
    4) die "$TO_REV failed its smoke test; $FROM_REV is live again (and $RELAY_PREV is marked failed)" 4 ;;
    *) down_checklist; die "rollback failed and the revert did not come up" 5 ;;
  esac
fi

# ── resolve the target revision ────────────────────────────────
git -C "$RELAY_REPO" rev-parse --git-dir >/dev/null 2>&1 || die "not a git clone: $RELAY_REPO"
REV="${REV:-$REMOTE/main}"

if [ "$DRY_RUN" = 1 ]; then
  if [ "$FETCH" = 1 ] && [ "$REV" = "$REMOTE/main" ]; then
    SHA="$(git -C "$RELAY_REPO" ls-remote "$REMOTE" refs/heads/main 2>/dev/null | awk '{print $1}' || true)"
    SHA="${SHA:-unresolved}"
    SHA_NOTE="(remote head via ls-remote; the real run fetches it)"
  else
    SHA="$(git -C "$RELAY_REPO" rev-parse --verify --quiet "$REV^{commit}" || echo "unresolved")"
    SHA_NOTE="(local refs; the real run fetches first unless --no-fetch)"
  fi
  PID_NOW="$(service_pid)"; STATE_NOW="$(service_state)"
  say "DRY RUN: nothing will be changed"
  say "service:   $SERVICE, state ${STATE_NOW:-not loaded}, pid ${PID_NOW:-none}, claude turns in flight: $( [ -n "$PID_NOW" ] && claude_children "$PID_NOW" || echo 0)"
  say "node:      $NODE ($("$NODE" --version)), npm: $NPM"
  say "live tree: $RELAY_HOME, revision $(revision_of "$RELAY_HOME"), status $(status_of "$RELAY_HOME")"
  if [ -e "$RELAY_PREV" ]; then
    say "previous:  $RELAY_PREV, revision $(revision_of "$RELAY_PREV"), status $(status_of "$RELAY_PREV"); a successful deploy replaces it"
  else
    say "previous:  $RELAY_PREV (absent)"
  fi
  if check_layout; then say "layout:    clean"; else say "layout:    the real run would REFUSE (see above)"; fi
  say "repo:      $RELAY_REPO (remote $REMOTE; work tree untouched)"
  say "target:    $REV = $SHA $SHA_NOTE"
  if [ "$(revision_of "$RELAY_HOME")" = "$SHA" ]; then
    if [ "$(status_of "$RELAY_HOME")" = ok ] && [ "$FORCE" = 0 ]; then
      say "note:      $SHA is already live (status ok): the real run only runs the auth probe (--force rebuilds and restarts)"
    else
      say "note:      $SHA is already live (status $(status_of "$RELAY_HOME")): the real run redeploys it and keeps $RELAY_PREV as the rollback target"
    fi
  fi
  say "build dir: $BUILD_ROOT/build-$SHA"
  say "free disk: $(df -k "$HOME" | awk 'NR==2 {printf "%.1f GB", $4/1048576}')"
  say "plan:"
  say "  1. git fetch $REMOTE; git archive $SHA relay/ into the build dir"
  say "  2. npm ci + npm run build with $NODE; load every dependency (native included) under it"
  say "  3. stage the build in $RELAY_NEXT; wait until no claude turn is in flight (up to ${IDLE_TIMEOUT}s)"
  say "  4. from here signals are ignored: re-check idle; swap code items, the live code becoming $RELAY_PREV"
  say "     moved now: $(present_items "$RELAY_HOME")"
  say "     untouched: $(untouched_items)"
  if launchctl print "$SERVICE" >/dev/null 2>&1; then
    say "  5. launchctl kickstart -k $SERVICE"
  else
    say "  5. launchctl bootstrap gui/$UID_N $PLIST (the service is not loaded now)"
  fi
  say "  6. smoke: new pid; 'Relay online as' + 'Reconcile scheduler started' in $LOG (fail fast on $ERR_LOG);"
  say "     GET 127.0.0.1:$NOTIFY_PORT/healthz; pid stable ${SMOKE_SETTLE}s"
  say "  7. on a failed smoke test: swap back, restart, smoke again, put the old $RELAY_PREV back (exit 4)"
  say "  8. auth probe $( [ "$AUTH_PROBE" = 1 ] && echo "on (timeout ${PROBE_TIMEOUT}s)" || echo off)"
  say "rollback later: $0 --rollback"
  exit 0
fi

# ── build ──────────────────────────────────────────────────────
begin_run
check_layout || die "earlier run left the layout unfinished (see above); nothing changed"
if [ "$FETCH" = 1 ]; then
  say "fetch: $REMOTE in $RELAY_REPO"
  git -C "$RELAY_REPO" fetch --quiet "$REMOTE" || die "git fetch $REMOTE failed"
fi
SHA="$(git -C "$RELAY_REPO" rev-parse --verify --quiet "$REV^{commit}")" || die "cannot resolve '$REV' in $RELAY_REPO"
SUBJECT="$(git -C "$RELAY_REPO" log -1 --format=%s "$SHA")" || die "git log failed"
SUMMARY="deploy $SHA (previous $(revision_of "$RELAY_HOME"))"
say "target: $REV = $SHA ($SUBJECT)"

if [ "$(revision_of "$RELAY_HOME")" = "$SHA" ] && [ "$(status_of "$RELAY_HOME")" = ok ] && [ "$FORCE" = 0 ] && [ "$BUILD_ONLY" = 0 ]; then
  SUMMARY="deploy $SHA: already live"
  say "already live: $SHA passed its smoke test; nothing to deploy, $RELAY_PREV kept as is (--force rebuilds and restarts)"
  PHASE=probe
  if [ "$AUTH_PROBE" = 1 ] && ! auth_probe; then
    SUMMARY="$SUMMARY, AUTH PROBE FAILED"
    die "$SHA is live, but the claude auth probe failed (see above). An auth error means Chuck cannot answer until the token is refreshed (infra/set-claude-token.sh); a timeout points at the network." 3
  fi
  exit 0
fi

avail_kb="$(df -k "$BUILD_ROOT" | awk 'NR==2 {print $4}')"
[ "${avail_kb:-0}" -gt 1048576 ] || die "less than 1 GB free under $BUILD_ROOT"

rm -rf "$BUILD_ROOT"/build-* "$BUILD_ROOT"/discard-*     # earlier builds are never reused
BUILD="$BUILD_ROOT/build-$SHA"
mkdir -p "$BUILD"
git -C "$RELAY_REPO" archive "$SHA" relay | LC_ALL=C tar -x -C "$BUILD" || die "git archive of $SHA failed"
NEW="$BUILD/relay"
[ -f "$NEW/package-lock.json" ] || die "no relay/package-lock.json at $SHA"

say "build: npm ci + npm run build in $NEW with node $("$NODE" --version)"
( cd "$NEW" && export PATH="$BUILD_PATH" npm_config_update_notifier=false \
  && "$NPM" ci --no-audit --no-fund --loglevel=error && "$NPM" run build --silent ) || die "npm ci / npm run build failed"
[ -f "$NEW/dist/index.js" ] || die "build produced no dist/index.js"

( cd "$NEW" && "$NODE" -e '
  const deps = Object.keys(require("./package.json").dependencies || {});
  for (const d of deps) require(d);
  if (deps.includes("better-sqlite3")) new (require("better-sqlite3"))(":memory:").close();
  console.log("relay-deploy: load check: " + deps.join(", ") + " ok under node " + process.version);
' ) || die "dependencies do not load under $NODE"

if [ "$BUILD_ONLY" = 1 ]; then
  SUMMARY="build-only $SHA"
  say "build only: $NEW is ready; nothing live changed"
  exit 0
fi

# ── stage ──────────────────────────────────────────────────────
for item in $REQUIRED_BUILD_ITEMS; do [ -e "$NEW/$item" ] || die "build lacks $item"; done
{
  echo "sha=$SHA"
  echo "ref=$REV"
  echo "subject=$SUBJECT"
  echo "deployed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "node=$("$NODE" --version)"
  echo "status=staged"
} > "$NEW/REVISION"
mkdir "$RELAY_NEXT_PARTIAL"; STAGED_NEXT=1
: > "$RELAY_NEXT_PARTIAL/$OWNED"
for item in $CODE_ITEMS; do
  if [ -e "$NEW/$item" ]; then mv "$NEW/$item" "$RELAY_NEXT_PARTIAL/$item"; fi
done
mv "$RELAY_NEXT_PARTIAL" "$RELAY_NEXT"          # complete: a .next is always a whole staged build
rm -rf "$BUILD"; BUILD=""
FROM_REV="$(rev_label "$RELAY_HOME")"
say "staged $SHA in $RELAY_NEXT"

# ── swap + activate (signals ignored from here) ────────────────
enter_critical
swap_code "$RELAY_NEXT"                         # live = new build; .next = code that was live
STAGED_NEXT=0
# What becomes of the code that was live (now in <live>.next):
#   rotated  proven, other commit: it becomes <live>.prev; the old .prev
#            waits in .prev.old until the outcome is known;
#   same     proven, same commit (--force): rotated too, so a failed restart
#            reverts to it, but on success the old .prev comes back (a copy
#            of the live commit is no rollback target);
#   dropped  never passed a smoke test: dropped; the proven .prev stays.
if rollbackable "$RELAY_NEXT"; then
  FATE=rotated; [ "$(revision_of "$RELAY_NEXT")" = "$SHA" ] && FATE=same
  if [ -e "$RELAY_PREV" ]; then mv "$RELAY_PREV" "$RELAY_PREV_OLD"; fi
  mv "$RELAY_NEXT" "$RELAY_PREV"
else
  FATE=dropped
  say "the code that was live ($FROM_REV) has status '$(status_of "$RELAY_NEXT")'; dropping it and keeping $RELAY_PREV as the rollback target"
  discard_dir "$RELAY_NEXT"
fi
REVERT_REV="$(rev_label "$RELAY_PREV")"; HAD_REVERT=0; [ -e "$RELAY_PREV" ] && HAD_REVERT=1
say "swapped: live = $SHA; revert target if the smoke test fails: $( [ -e "$RELAY_PREV" ] && echo "$REVERT_REV (status $(status_of "$RELAY_PREV"))" || echo none)"

rc=0; activate || rc=$?
if [ "$rc" = 0 ]; then
  if [ "$FATE" = same ]; then
    discard_dir "$RELAY_PREV"
    if [ -e "$RELAY_PREV_OLD" ]; then mv "$RELAY_PREV_OLD" "$RELAY_PREV"; fi
  else
    discard_dir "$RELAY_PREV_OLD"
  fi
else
  # The failed build is in <live>.prev now: drop it, and put the older
  # rollback target back where there is one.
  discard_dir "$RELAY_PREV"
  if [ -e "$RELAY_PREV_OLD" ]; then mv "$RELAY_PREV_OLD" "$RELAY_PREV"; fi
fi
leave_critical
case "$rc:$FATE" in
  0:*) ;;
  4:dropped) die "deploy of $SHA failed its smoke test; the rollback target $REVERT_REV is live; the unproven code that was live before ($FROM_REV) was dropped, so there is no rollback target now" 4 ;;
  4:*) die "deploy of $SHA failed its smoke test; $FROM_REV is live again and $RELAY_PREV is as before" 4 ;;
  *) if [ "$HAD_REVERT" = 0 ]; then
       die "deploy of $SHA failed its smoke test and there was no proven code to revert to; $SHA stays live. Check the cause (network, Discord, .env, $ERR_LOG), then re-run the deploy" 5
     fi
     down_checklist; die "deploy of $SHA failed and the code it reverted to ($REVERT_REV) did not come up either" 5 ;;
esac

if [ "$AUTH_PROBE" = 1 ] && ! auth_probe; then
  SUMMARY="$SUMMARY, AUTH PROBE FAILED"
  die "deployed $SHA, but the claude auth probe failed (see above). An auth error means Chuck cannot answer until the token is refreshed (infra/set-claude-token.sh); a timeout points at the network. The code stays: rolling back would not change either." 3
fi
say "deployed $SHA; rollback: $0 --rollback"
