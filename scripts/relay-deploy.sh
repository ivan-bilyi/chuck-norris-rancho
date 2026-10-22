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
#   3. waits until Relay has no claude child process (no turn in flight);
#   4. swaps only the CODE items of the live tree (CODE_ITEMS below) and keeps
#      the previous code in <live>.prev, so rollback is one command;
#   5. restarts the service with launchctl kickstart (or loads it with
#      launchctl bootstrap when it is not loaded) and smoke-tests it: new
#      pid running, "Relay online as" (Discord ready) and "Reconcile scheduler
#      started" in the log, GET /healthz = 200 on the notify port, pid stable,
#      then a one-line claude auth probe with Relay's token. If the service
#      checks fail it swaps the previous code back and restarts again.
#
# State in the live tree (.env*, relay.db*, logs/ and anything else that is
# not a CODE item) is never moved or written. The script reads only the
# service log and two settings from .env: RELAY_NOTIFY_PORT and, for the auth
# probe, CLAUDE_CODE_OAUTH_TOKEN (passed to claude in its environment, never
# printed).
#
# The deployed revision is recorded in <live>/REVISION as key=value lines:
#   sha=<40-hex commit>   ref=<requested rev>   subject=<commit subject>
#   deployed_at=<UTC ISO-8601>   node=<node version>
# It is a CODE item, so a rollback brings back the previous record too.
# No REVISION file means the live code was not deployed by this script.
#
# Usage:
#   scripts/relay-deploy.sh [--sha <rev>] [--dry-run] [--build-only]
#                           [--no-fetch] [--no-wait] [--no-auth-probe]
#   scripts/relay-deploy.sh --rollback [--dry-run]
#
#   --sha <rev>      what to deploy (default: <remote>/main, after a fetch)
#   --dry-run        print the plan and the current state; change nothing
#   --build-only     fetch + build + load check only; no swap, no restart
#   --no-fetch       use the refs already in the clone
#   --no-wait        do not wait for in-flight claude turns (they are killed)
#   --no-auth-probe  skip the claude auth probe
#   --rollback       swap the live code and <live>.prev back, then restart and
#                    smoke-test (running it twice returns to where you were).
#                    Refuses code that failed its smoke test. If the rollback
#                    target fails, the code you had is swapped back in.
#
# Exit codes: 0 deployed (or dry run / build ok); 1 failed before anything
# live changed; 2 usage; 3 deployed but the auth probe failed (code stays;
# rolling back would not fix auth); 4 smoke test failed and the code that was
# live before is live again; 5 smoke test failed and the revert did not come
# up either (look at the service by hand).
#
# Settings (environment; defaults come from the launchd plist and $HOME):
#   RELAY_LABEL          launchd label                (com.rancho.relay)
#   RELAY_PLIST          plist of that label          (~/Library/LaunchAgents/<label>.plist)
#   RELAY_HOME           live tree                    (plist WorkingDirectory)
#   RELAY_PREV           previous code                (<live>.prev)
#   RELAY_REPO           git clone to build from      (the repo holding this script)
#   RELAY_REMOTE         remote to fetch              (origin)
#   RELAY_BUILD_ROOT     builds, lock, history        (${XDG_CACHE_HOME:-~/.cache}/relay-deploy)
#   RELAY_NOTIFY_PORT    healthz port                 (.env RELAY_NOTIFY_PORT, else 4466)
#   RELAY_IDLE_TIMEOUT   seconds to wait for idle     (900)
#   RELAY_SMOKE_TIMEOUT  seconds for the ready checks (90)
#   RELAY_SMOKE_SETTLE   seconds the new pid must stay up (10)
set -euo pipefail

# Code items of the live tree: everything a build produces, nothing else.
# The first five are what the service runs; the rest are the matching sources
# so the live tree never shows code that differs from what runs.
CODE_ITEMS="dist node_modules package.json package-lock.json REVISION src tsconfig.json CLAUDE.md relay.env.example templates"
REQUIRED_BUILD_ITEMS="dist node_modules package.json package-lock.json"
PREV_MARKER=".relay-deploy-prev"

say() { printf 'relay-deploy: %s\n' "$*"; }
die() { printf 'relay-deploy: ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

# ── arguments ──────────────────────────────────────────────────
REV=""; DRY_RUN=0; BUILD_ONLY=0; FETCH=1; WAIT_IDLE=1; AUTH_PROBE=1; ROLLBACK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sha) [ $# -ge 2 ] || die "--sha needs a revision" 2; REV="$2"; shift 2 ;;
    --sha=*) REV="${1#--sha=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --build-only) BUILD_ONLY=1; shift ;;
    --no-fetch) FETCH=0; shift ;;
    --no-wait) WAIT_IDLE=0; shift ;;
    --no-auth-probe) AUTH_PROBE=0; shift ;;
    --rollback) ROLLBACK=1; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" 2 ;;
  esac
done
if [ "$ROLLBACK" = 1 ] && { [ -n "$REV" ] || [ "$BUILD_ONLY" = 1 ]; }; then
  die "--rollback takes no --sha/--build-only" 2
fi

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
SWAP_TMP="$RELAY_HOME.swap"
LOG="$(plist_get StandardOutPath)"
ERR_LOG="$(plist_get StandardErrorPath)"
SERVICE_PATH="$(plist_get EnvironmentVariables.PATH)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELAY_REPO="${RELAY_REPO:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$HOME/chuck-norris-rancho")}"
REMOTE="${RELAY_REMOTE:-origin}"
BUILD_ROOT="${RELAY_BUILD_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/relay-deploy}"
IDLE_TIMEOUT="${RELAY_IDLE_TIMEOUT:-900}"
SMOKE_TIMEOUT="${RELAY_SMOKE_TIMEOUT:-90}"
SMOKE_SETTLE="${RELAY_SMOKE_SETTLE:-10}"

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

# ── service helpers ────────────────────────────────────────────
service_field() { { launchctl print "$SERVICE" 2>/dev/null || true; } | awk -v k="$1" '$1 == k && $2 == "=" { print $3; exit }'; }
service_pid() { service_field pid; }
service_state() { service_field state; }
claude_children() { { pgrep -P "$1" -f claude 2>/dev/null || true; } | wc -l | tr -d ' '; }
log_size() { if [ -n "$LOG" ] && [ -f "$LOG" ]; then stat -f %z "$LOG"; else echo 0; fi; }
revision_of() { if [ -f "$1/REVISION" ]; then sed -n 's/^sha=//p' "$1/REVISION" | head -n 1; else echo "unrecorded"; fi; }

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

# Exchange the code items of the live tree and <live>.prev (a rename per item,
# through a sibling temp dir). Nothing is deleted. Used for deploy and rollback.
swap_code() {
  local item
  [ ! -e "$SWAP_TMP" ] || die "$SWAP_TMP exists (interrupted swap?); inspect it before retrying"
  mkdir "$SWAP_TMP"
  for item in $CODE_ITEMS; do
    if [ -e "$RELAY_HOME/$item" ] || [ -L "$RELAY_HOME/$item" ]; then mv "$RELAY_HOME/$item" "$SWAP_TMP/$item"; fi
  done
  for item in $CODE_ITEMS; do
    if [ -e "$RELAY_PREV/$item" ] || [ -L "$RELAY_PREV/$item" ]; then mv "$RELAY_PREV/$item" "$RELAY_HOME/$item"; fi
  done
  for item in $CODE_ITEMS; do
    if [ -e "$SWAP_TMP/$item" ] || [ -L "$SWAP_TMP/$item" ]; then mv "$SWAP_TMP/$item" "$RELAY_PREV/$item"; fi
  done
  rmdir "$SWAP_TMP"
}

# The ready lines must appear in the log after byte offset $1.
log_since() {
  local from="$1" size
  size="$(log_size)"
  [ "$size" -ge "$from" ] || from=0   # the log was rotated meanwhile
  tail -c "+$((from + 1))" "$LOG" 2>/dev/null || true
}

smoke() {
  local old_pid="$1" from="$2" deadline pid="" out
  deadline=$(( $(date +%s) + SMOKE_TIMEOUT ))
  while :; do
    pid="$(service_pid)"
    if [ -n "$pid" ] && [ "$pid" != "$old_pid" ] && [ "$(service_state)" = "running" ]; then break; fi
    [ "$(date +%s)" -lt "$deadline" ] || { say "smoke: service did not come up with a new pid"; return 1; }
    sleep 1
  done
  say "smoke: running, pid $pid"
  while :; do
    out="$(log_since "$from")"
    case "$out" in *"Failed to start bot"*) say "smoke: log says 'Failed to start bot'"; return 1 ;; esac
    case "$out" in *"Relay online as"*)
      case "$out" in *"Reconcile scheduler started"*) break ;; esac ;;
    esac
    [ "$(date +%s)" -lt "$deadline" ] || { say "smoke: no 'Relay online as' + 'Reconcile scheduler started' in $LOG"; return 1; }
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
    say "smoke: pid changed or service stopped within ${SMOKE_SETTLE}s (crash loop?)"; return 1
  fi
  say "smoke: pid $pid stable for ${SMOKE_SETTLE}s"
}

# One cheap claude turn with Relay's own token: proves the subscription auth
# that every spawned session uses. Runs in a fixed scratch dir with no MCP
# servers and no saved session.
auth_probe() {
  local claude_bin dir out
  claude_bin="$(PATH="$PROBE_PATH" command -v claude || true)"
  [ -n "$claude_bin" ] || { say "auth probe: claude not found on the service PATH"; return 1; }
  dir="$BUILD_ROOT/auth-probe"; mkdir -p "$dir"
  out="$(
    cd "$dir"
    token="$(env_setting CLAUDE_CODE_OAUTH_TOKEN)"
    if [ -n "$token" ]; then export CLAUDE_CODE_OAUTH_TOKEN="$token"; fi
    PATH="$PROBE_PATH" "$claude_bin" -p "Reply with just: OK" --output-format json \
      --no-session-persistence --strict-mcp-config --model haiku </dev/null 2>&1 || true
  )"
  case "$out" in *'"is_error":false'*) say "auth probe: ok"; return 0 ;; esac
  say "auth probe: FAILED: $(printf '%s' "$out" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).result)}catch{console.log(s.slice(0,300))}})')"
  return 1
}

restart_and_smoke() {
  local old_pid from
  old_pid="$(service_pid)"; from="$(log_size)"
  if launchctl print "$SERVICE" >/dev/null 2>&1; then
    say "restart: launchctl kickstart -k $SERVICE"
    launchctl kickstart -k "$SERVICE"
  else
    say "start: launchctl bootstrap gui/$UID_N $PLIST (the service was not loaded)"
    launchctl bootstrap "gui/$UID_N" "$PLIST"
  fi
  smoke "$old_pid" "$from"
}

# After a swap: restart and smoke-test. If that fails, swap the code back and
# restart again; <live>.prev then holds the code that failed and is marked so,
# which --rollback refuses. Returns 0 (live), 4 (reverted), 5 (revert failed).
activate() {
  if restart_and_smoke; then echo ok > "$RELAY_PREV/$PREV_MARKER"; return 0; fi
  say "smoke test failed: swapping the code back"
  swap_code
  echo failed > "$RELAY_PREV/$PREV_MARKER"
  if restart_and_smoke; then return 4; fi
  return 5
}

record_history() {
  mkdir -p "$BUILD_ROOT"
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$BUILD_ROOT/history.log"
}

wait_idle() {
  local pid n deadline
  [ "$WAIT_IDLE" = 1 ] || { say "not waiting for in-flight turns (--no-wait)"; return 0; }
  pid="$(service_pid)"; [ -n "$pid" ] || return 0
  deadline=$(( $(date +%s) + IDLE_TIMEOUT ))
  while n="$(claude_children "$pid")"; [ "$n" != "0" ]; do
    [ "$(date +%s)" -lt "$deadline" ] || die "Relay still has $n claude turn(s) in flight after ${IDLE_TIMEOUT}s; nothing changed"
    say "waiting: $n claude turn(s) in flight"
    sleep 5
  done
}

acquire_lock() {
  mkdir -p "$BUILD_ROOT"
  mkdir "$BUILD_ROOT/lock" 2>/dev/null \
    || die "another deploy holds $BUILD_ROOT/lock (remove it if no deploy is running)"
  trap 'rmdir "$BUILD_ROOT/lock" 2>/dev/null || true' EXIT
}

# ── rollback ───────────────────────────────────────────────────
if [ "$ROLLBACK" = 1 ]; then
  [ -f "$RELAY_PREV/$PREV_MARKER" ] || die "no previous code at $RELAY_PREV"
  [ "$(cat "$RELAY_PREV/$PREV_MARKER")" = "ok" ] \
    || die "the code in $RELAY_PREV is marked '$(cat "$RELAY_PREV/$PREV_MARKER")' (it failed its smoke test or was never live); not rolling back to it"
  TO_REV="$(revision_of "$RELAY_PREV")"; FROM_REV="$(revision_of "$RELAY_HOME")"
  say "live:     $RELAY_HOME (revision $FROM_REV)"
  say "previous: $RELAY_PREV (revision $TO_REV): $(present_items "$RELAY_PREV")"
  if [ "$DRY_RUN" = 1 ]; then
    say "dry run: would swap those items with the live ones, kickstart $SERVICE and smoke-test; nothing changed"
    exit 0
  fi
  acquire_lock; wait_idle
  swap_code
  say "swapped: live revision is now $TO_REV"
  rc=0; activate || rc=$?
  case "$rc" in
    0) record_history "rollback $FROM_REV -> $TO_REV ok"
       say "rollback done; run --rollback again to return to $FROM_REV"; exit 0 ;;
    4) record_history "rollback $FROM_REV -> $TO_REV SMOKE FAILED, $FROM_REV live again"
       die "$TO_REV failed its smoke test; $FROM_REV is live again" 4 ;;
    *) record_history "rollback $FROM_REV -> $TO_REV SMOKE FAILED, revert ALSO FAILED"
       die "rollback failed and the revert did not come up; see $LOG and $ERR_LOG" 5 ;;
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
  PID_NOW="$(service_pid)"
  say "DRY RUN: nothing will be changed"
  STATE_NOW="$(service_state)"
  say "service:   $SERVICE, state ${STATE_NOW:-not loaded}, pid ${PID_NOW:-none}, claude turns in flight: $( [ -n "$PID_NOW" ] && claude_children "$PID_NOW" || echo 0)"
  say "node:      $NODE ($("$NODE" --version)), npm: $NPM"
  say "live tree: $RELAY_HOME, deployed revision: $(revision_of "$RELAY_HOME")"
  say "previous:  $RELAY_PREV ($( [ -f "$RELAY_PREV/$PREV_MARKER" ] && echo "revision $(revision_of "$RELAY_PREV"), will be replaced" || { [ -e "$RELAY_PREV" ] && echo "EXISTS WITHOUT MARKER: the real run refuses" || echo "absent"; } ))"
  say "repo:      $RELAY_REPO (remote $REMOTE; work tree untouched)"
  say "target:    $REV = $SHA $SHA_NOTE"
  say "build dir: $BUILD_ROOT/build-$SHA"
  say "free disk: $(df -k "$HOME" | awk 'NR==2 {printf "%.1f GB", $4/1048576}')"
  say "plan:"
  say "  1. git fetch $REMOTE; git archive $SHA relay/ into the build dir"
  say "  2. npm ci + npm run build with $NODE; load every dependency (native included) under it"
  say "  3. write REVISION; wait until no claude turn is in flight (up to ${IDLE_TIMEOUT}s)"
  say "  4. live code -> $RELAY_PREV, new code -> $RELAY_HOME (renames only)"
  say "     moved now: $(present_items "$RELAY_HOME")"
  say "     untouched: $(untouched_items)"
  if launchctl print "$SERVICE" >/dev/null 2>&1; then
    say "  5. launchctl kickstart -k $SERVICE"
  else
    say "  5. launchctl bootstrap gui/$UID_N $PLIST (the service is not loaded now)"
  fi
  say "  6. smoke: new pid; 'Relay online as' + 'Reconcile scheduler started' in $LOG;"
  say "     GET 127.0.0.1:$NOTIFY_PORT/healthz; pid stable ${SMOKE_SETTLE}s; auth probe $( [ "$AUTH_PROBE" = 1 ] && echo on || echo off)"
  say "  7. on a failed service check: swap back, restart, smoke again (exit 4)"
  say "rollback later: $0 --rollback"
  exit 0
fi

# ── build ──────────────────────────────────────────────────────
acquire_lock
if [ "$FETCH" = 1 ]; then
  say "fetch: $REMOTE in $RELAY_REPO"
  git -C "$RELAY_REPO" fetch --quiet "$REMOTE"
fi
SHA="$(git -C "$RELAY_REPO" rev-parse --verify --quiet "$REV^{commit}")" || die "cannot resolve '$REV' in $RELAY_REPO"
SUBJECT="$(git -C "$RELAY_REPO" log -1 --format=%s "$SHA")"
say "target: $REV = $SHA ($SUBJECT)"

avail_kb="$(df -k "$BUILD_ROOT" | awk 'NR==2 {print $4}')"
[ "${avail_kb:-0}" -gt 1048576 ] || die "less than 1 GB free under $BUILD_ROOT"

BUILD="$BUILD_ROOT/build-$SHA"
rm -rf "$BUILD_ROOT"/build-*          # earlier builds are never reused
mkdir -p "$BUILD"
git -C "$RELAY_REPO" archive "$SHA" relay | LC_ALL=C tar -x -C "$BUILD"
NEW="$BUILD/relay"
[ -f "$NEW/package-lock.json" ] || die "no relay/package-lock.json at $SHA"

say "build: npm ci + npm run build in $NEW with node $("$NODE" --version)"
( cd "$NEW" && export PATH="$BUILD_PATH" npm_config_update_notifier=false \
  && "$NPM" ci --no-audit --no-fund --loglevel=error && "$NPM" run build --silent )
[ -f "$NEW/dist/index.js" ] || die "build produced no dist/index.js"

( cd "$NEW" && "$NODE" -e '
  const deps = Object.keys(require("./package.json").dependencies || {});
  for (const d of deps) require(d);
  if (deps.includes("better-sqlite3")) new (require("better-sqlite3"))(":memory:").close();
  console.log("relay-deploy: load check: " + deps.join(", ") + " ok under node " + process.version);
' ) || die "dependencies do not load under $NODE"

if [ "$BUILD_ONLY" = 1 ]; then
  say "build only: $NEW is ready; nothing live changed"
  exit 0
fi

# ── swap ───────────────────────────────────────────────────────
for item in $REQUIRED_BUILD_ITEMS; do [ -e "$NEW/$item" ] || die "build lacks $item"; done
if [ -e "$RELAY_PREV" ] && [ ! -f "$RELAY_PREV/$PREV_MARKER" ]; then
  die "$RELAY_PREV exists but was not made by this script; move it away first"
fi

wait_idle

{
  echo "sha=$SHA"
  echo "ref=$REV"
  echo "subject=$SUBJECT"
  echo "deployed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "node=$("$NODE" --version)"
} > "$NEW/REVISION"

# Stage the new code as <live>.prev, then exchange it with the live code.
rm -rf "$RELAY_PREV"
mkdir "$RELAY_PREV"
echo staged > "$RELAY_PREV/$PREV_MARKER"
for item in $CODE_ITEMS; do
  if [ -e "$NEW/$item" ]; then mv "$NEW/$item" "$RELAY_PREV/$item"; fi
done
FROM_REV="$(revision_of "$RELAY_HOME")"
swap_code
say "swapped: live = $SHA, previous ($FROM_REV) kept in $RELAY_PREV"

rc=0; activate || rc=$?
rm -rf "$BUILD"
case "$rc" in
  0) ;;
  4) record_history "deploy $SHA SMOKE FAILED, rolled back to $FROM_REV"
     die "deploy of $SHA failed its smoke test; $FROM_REV is live again. The failed build is in $RELAY_PREV" 4 ;;
  *) record_history "deploy $SHA SMOKE FAILED, rollback to $FROM_REV ALSO FAILED"
     die "deploy of $SHA failed AND the rollback did not come up; see $LOG and $ERR_LOG" 5 ;;
esac
if [ "$AUTH_PROBE" = 1 ] && ! auth_probe; then
  record_history "deploy $SHA ok, AUTH PROBE FAILED"
  die "deployed $SHA, but the claude auth probe failed: Chuck cannot answer until the token is fixed (infra/set-claude-token.sh). Code stays." 3
fi
record_history "deploy $SHA ok (previous $FROM_REV)"
say "deployed $SHA; rollback: $0 --rollback"
