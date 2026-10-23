#!/usr/bin/env bash
# tailscaled cutover: move this Mac from the Tailscale GUI app to the
# open-source tailscaled running as a system LaunchDaemon.
#
# Why: the GUI app (the standalone "macsys" variant, a system network
# extension) connects only inside a logged-in GUI session and can come back
# "Stopped" after a reboot. tailscaled as a LaunchDaemon starts at boot,
# before any login, and keeps its own state.
#
# Run it ON the host, as root, from a LAN SSH session: the tailnet path drops
# during the cutover. --detach keeps it running if that session dies.
#
#   sudo bash infra/tailscaled/cutover.sh --preflight
#   sudo bash infra/tailscaled/cutover.sh --hostname <name> --detach
#   sudo bash infra/tailscaled/cutover.sh --rollback --detach
#
# Starting point. A first cutover (no daemon installed and loaded yet) starts
# only from a known-good state:
#   - the GUI app answers and is Running with a tailnet IPv4. With no app at
#     $APP, no Tailscale VPN service may be configured and no Tailscale GUI or
#     network-extension process may run (an app elsewhere is not controllable);
#   - no process other than Tailscale's own (tailscaled, the GUI app, its
#     network extension) has a TCP listening socket or a UDP socket on a
#     tailnet address (100.64.0.0/10 or fd7a:115c:a1e0::/48). Such a process
#     fails while the address is gone (a DNS server bound there crash-loops).
#     Wildcard, loopback and LAN binds are fine. Both lsof listings are
#     bounded in time and must return something, or the check fails closed.
# Before changing anything it records the GUI app's non-secret prefs
# (GUI_PREF_KEYS) in the log dir, for the rollback.
#
# --preflight changes nothing. It reports the Homebrew `tailscale` formula,
# the GUI app (state, prefs, VPN service, start on login, login-item
# helper), the daemon, and the starting-point checks above. It records the
# GUI prefs and saves the active serve/funnel config to the log dir.
# Exit 0 = ready (or already cut over), 1 = not ready.
#
# Cutover (the default). Each step checks first and acts only on drift:
#   1. GUI app: `down` through its own CLI (run as the GUI user with
#      TAILSCALE_BE_CLI=1) until its VPN service is disconnected and its
#      WantRunning is off; turn off TailscaleStartOnLogin (defaults domain
#      io.tailscale.ipn.macsys, written as the user); disable its login-item
#      helper for the user (`launchctl disable gui/<uid>/<helper bundle id>`,
#      persistent); quit the app.
#   2. `tailscaled install-system-daemon` from the Homebrew formula. It copies
#      the binary to /usr/local/bin/tailscaled, writes
#      /Library/LaunchDaemons/com.tailscale.tailscaled.plist (RunAtLoad) and
#      starts the job. State: /Library/Tailscale/tailscaled.state. CLI socket:
#      /var/run/tailscaled.socket.
#   3. Wait for the daemon to answer, then `tailscale up --reset` with the
#      carried-over prefs (UP_FLAGS) plus --operator=<GUI user> and
#      --hostname. A new node gets a login URL: the log shows it in a banner
#      and the run waits (TS_CUTOVER_LOGIN_TIMEOUT) for someone to approve it.
#   4. Re-create the serve/funnel mounts (SERVE_MOUNTS) under the node's
#      current DNS name when they differ.
#   5. Verify: daemon backend Running with a tailnet IPv4, prefs as
#      configured, serve and funnel as configured, the plist with RunAtLoad
#      and the job loaded (whether it really comes up at boot needs a reboot,
#      a separate step), the GUI app disconnected with WantRunning off (when it
#      answers), not starting on login, its helper disabled.
# A re-run after success changes nothing and only verifies. After the node is
# renamed in the admin console, a re-run moves the serve mounts to the new name.
#
# --rollback first proves that the GUI app can come back: the GUI user must
# have a GUI session, the app is launched there (it stays disconnected) and
# its backend must answer; if it answers NeedsLogin, the prefs record must
# exist. Otherwise it refuses and changes nothing. Then:
# `tailscaled uninstall-system-daemon` (stops and unloads the job, removes the
# plist and /usr/local/bin/tailscaled; the state file stays), re-enable the
# helper and start on login, a bare `tailscale up` on the app (sets only
# WantRunning, so the app's own prefs stay as they were), check the serve
# mounts, verify, including the recorded GUI prefs. If the app's node was
# deleted meanwhile (NeedsLogin), it runs `up --reset` with flags rebuilt from
# the recorded prefs instead, and the log shows the login URL. An exit node
# cannot be restored from its recorded ID: it is only warned about, never
# part of the verification.
#
# Every daemon call passes --socket explicitly: without it, the Homebrew CLI
# on macOS talks to the GUI app's backend whenever that one answers.
#
# When a run fails or is stopped, the end of its output and log says, in this
# order: whether Tailscale is DOWN on the host now (neither backend Running),
# the rollback command, what failed, and "finished: exit <code>".
#
# Usage:
#   cutover.sh --preflight [--user <name>]
#   cutover.sh --hostname <name> [--user <name>] [--detach]
#   cutover.sh --rollback [--user <name>] [--detach]
#
#   --hostname <name>  the node's hostname (required until the daemon is
#                      Running; checked against the prefs when given later)
#   --user <name>      the GUI user: runs the app's CLI, becomes the daemon's
#                      operator, owns the log dir (default: $SUDO_USER)
#   --detach           run in the background (nohup) and return at once; the
#                      log's last line is "tailscaled-cutover: finished: exit <code>"
#
# Log dir: <user home>/.cache/tailscaled-cutover: last-run.log, history.log,
# preflight.log, gui-prefs.txt (the recorded GUI prefs), serve-config-<UTC>.json
# (saved by --preflight), detached.out (stray output of a --detach run).
#
# Exit codes: 0 ok; 1 failed or not ready (the message says whether anything
# changed and how to go back); 2 usage.
#
# Settings (environment). The defaults are the real host paths. The path
# overrides exist for the test harness:
#   TS_CUTOVER_LOGIN_TIMEOUT    seconds to wait for the login approval (900)
#   TS_CUTOVER_BACKEND_TIMEOUT  seconds to wait for a backend to answer or settle (90)
#   TS_CUTOVER_CMD_TIMEOUT      seconds for one CLI call (60)
#   TS_CUTOVER_POLL             seconds between polls (2)
#   TS_CUTOVER_IGNORE_BOUND=1   cut over even though processes bind a tailnet address
#   TS_CUTOVER_APP  TS_CUTOVER_BREW  TS_CUTOVER_DAEMON_PLIST  TS_CUTOVER_DAEMON_BIN
#   TS_CUTOVER_SOCKET  TS_CUTOVER_LOG_DIR  TS_CUTOVER_PATH
set -uo pipefail
# fd 3 is where this run talks (the terminal, or detached.out); fd 4, once
# open, is the run's log. Output goes only there, never to the current
# stdout, which may be a redirect into a temp file when a signal arrives.
exec 3>&1
ORIG_ARGS=("$@")

# ── configuration ──────────────────────────────────────────────
# Serve/funnel mounts of the node, one per line:
#   <https port>  <path>  <target>  <funnel|tailnet>
# funnel = public on the internet (Funnel takes ports 443, 8443 and 10000
# only); tailnet = reachable from the tailnet only. This is the node's whole
# serve config: anything else found there is reset.
SERVE_MOUNTS='
443   /  http://127.0.0.1:4477  funnel
8444  /  http://127.0.0.1:4477  tailnet
'
# Daemon prefs, carried over from the GUI app. `up --reset` sets every pref
# not named here to its default: no exit node, no advertised routes, no
# Tailscale SSH. EXPECT_PREFS is what verification reads back from `tailscale
# debug prefs` (empty = unset or false). Keep the two in step.
UP_FLAGS=(--accept-routes --accept-dns)
EXPECT_PREFS="RouteAll=true CorpDNS=true RunSSH= ExitNodeID= AdvertiseRoutes= WantRunning=true"
# The GUI app's prefs recorded before the cutover and checked after a rollback.
GUI_PREF_KEYS="Hostname RouteAll CorpDNS ShieldsUp AdvertiseTags AdvertiseRoutes ExitNodeID RunSSH"
# Where Homebrew may live, first match wins (TS_CUTOVER_BREW goes first).
BREW_CANDIDATES="/opt/homebrew/bin/brew /usr/local/bin/brew"

APP_ID="io.tailscale.ipn.macsys"                       # bundle id and defaults domain of the app
APP="${TS_CUTOVER_APP:-/Applications/Tailscale.app}"
APP_BIN="$APP/Contents/MacOS/Tailscale"                 # doubles as its CLI with TAILSCALE_BE_CLI=1
SENTINEL_LABEL="io.tailscale.ipn.macsys.tssentineld"    # the app's Always-On helper (MDM policy only)
# The label, plist, binary and socket are fixed by `tailscaled install-system-daemon`.
DAEMON_LABEL="com.tailscale.tailscaled"
DAEMON_PLIST="${TS_CUTOVER_DAEMON_PLIST:-/Library/LaunchDaemons/$DAEMON_LABEL.plist}"
DAEMON_BIN="${TS_CUTOVER_DAEMON_BIN:-/usr/local/bin/tailscaled}"
SOCKET="${TS_CUTOVER_SOCKET:-/var/run/tailscaled.socket}"
STATE_FILE="/Library/Tailscale/tailscaled.state"
LOGIN_TIMEOUT="${TS_CUTOVER_LOGIN_TIMEOUT:-900}"
BACKEND_TIMEOUT="${TS_CUTOVER_BACKEND_TIMEOUT:-90}"
CMD_TIMEOUT="${TS_CUTOVER_CMD_TIMEOUT:-60}"
POLL="${TS_CUTOVER_POLL:-2}"
# sudo and launchd give no reliable PATH: use the system dirs only.
export PATH="${TS_CUTOVER_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"
# JavaScript for Automation parses the CLI's JSON (older macOS has no jq).
JSON_ENGINE=/usr/bin/osascript

# ── output ─────────────────────────────────────────────────────
NAME=tailscaled-cutover
LOG_OPEN=0
say() {
  local line="$NAME: $*"
  printf '%s\n' "$line" >&3 2>/dev/null || true
  if [ "$LOG_OPEN" = 1 ]; then printf '%s\n' "$line" >&4 2>/dev/null || true; fi
}
usage_die() { say "ERROR: $1"; exit 2; }

CHANGED=0        # 1 once this run changed anything on the host
FAIL_STEP=""; FAIL_MSG=""
fail() {         # fail <step> <message>: stop the run; on_exit reports state, rollback, then this
  FAIL_STEP="$1"; shift
  FAIL_MSG="$*"
  exit 1
}

# ── arguments ──────────────────────────────────────────────────
MODE=""; HOST=""; OPT_USER=""; DETACH=0
set_mode() { [ -z "$MODE" ] || usage_die "choose one of --preflight, --rollback or the cutover"; MODE="$1"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --preflight) set_mode preflight; shift ;;
    --rollback) set_mode rollback; shift ;;
    --hostname) [ $# -ge 2 ] || usage_die "--hostname needs a value"; HOST="$2"; shift 2 ;;
    --hostname=*) HOST="${1#--hostname=}"; shift ;;
    --user) [ $# -ge 2 ] || usage_die "--user needs a value"; OPT_USER="$2"; shift 2 ;;
    --user=*) OPT_USER="${1#--user=}"; shift ;;
    --detach) DETACH=1; shift ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) usage_die "unknown argument: $1 (see --help)" ;;
  esac
done
MODE="${MODE:-cutover}"
if [ -n "$HOST" ]; then
  [ "$MODE" = cutover ] || usage_die "--hostname belongs to the cutover only"
  [[ "$HOST" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || usage_die "invalid --hostname '$HOST' (letters, digits, '-'; max 63)"
fi
[ "$MODE" != preflight ] || [ "$DETACH" = 0 ] || usage_die "--preflight runs in the foreground; drop --detach"
[ "$(id -u)" = 0 ] || usage_die "run it as root: sudo bash $0 ${ORIG_ARGS[*]+${ORIG_ARGS[*]}}"

# ── host facts ─────────────────────────────────────────────────
GUI_USER="${OPT_USER:-${SUDO_USER:-}}"
[ -n "$GUI_USER" ] && [ "$GUI_USER" != root ] \
  || usage_die "cannot tell the GUI user: run it with sudo from that user's account, or pass --user <name>"
GUI_UID="$(id -u "$GUI_USER" 2>/dev/null)" || usage_die "no such user: $GUI_USER"
USER_HOME="$(dscl . -read "/Users/$GUI_USER" NFSHomeDirectory 2>/dev/null | awk '{ print $2; exit }')"
[ -n "$USER_HOME" ] && [ -d "$USER_HOME" ] || usage_die "home directory of $GUI_USER not found"
CONSOLE_USER="$(stat -f%Su /dev/console 2>/dev/null || true)"
LOG_DIR="${TS_CUTOVER_LOG_DIR:-$USER_HOME/.cache/tailscaled-cutover}"
LOCK="$LOG_DIR/lock"
GUI_PREFS_FILE="$LOG_DIR/gui-prefs.txt"
SCRIPT_ABS="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
ROLLBACK_CMD="sudo bash $SCRIPT_ABS --rollback --detach"

as_user() { sudo -u "$GUI_USER" -H "$@"; }

# Homebrew prefix, asked as the user (brew refuses root); the formula's own
# opt path, so a CLI link left by the app's cask cannot stand in for it.
BREW=""; BREW_PREFIX=""; TS_CLI=""; TSD=""
resolve_brew() {
  local b
  # shellcheck disable=SC2086  # BREW_CANDIDATES is a word list
  for b in ${TS_CUTOVER_BREW:+"$TS_CUTOVER_BREW"} $BREW_CANDIDATES; do
    [ -x "$b" ] || continue
    BREW="$b"
    BREW_PREFIX="$(as_user "$b" --prefix 2>/dev/null | tail -n 1)"
    [ -n "$BREW_PREFIX" ] || BREW_PREFIX="$(dirname "$(dirname "$b")")"
    break
  done
  if [ -n "$BREW_PREFIX" ]; then
    TS_CLI="$BREW_PREFIX/opt/tailscale/bin/tailscale"
    TSD="$BREW_PREFIX/opt/tailscale/bin/tailscaled"
  fi
}
formula_ok() { [ -n "$TS_CLI" ] && [ -x "$TS_CLI" ] && [ -x "$TSD" ]; }

# The app's login-item helper: its launchd label in gui/<uid> is the bundle
# id from its Info.plist.
HELPER_LABEL=""
resolve_helper() {
  local p
  for p in "$APP"/Contents/Library/LoginItems/*.app/Contents/Info.plist; do
    [ -f "$p" ] || continue
    HELPER_LABEL="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$p" 2>/dev/null || true)"
    [ -z "$HELPER_LABEL" ] || break
  done
}

# ── helpers ────────────────────────────────────────────────────
TMP=""
make_tmp() { TMP="$(mktemp -d "${TMPDIR:-/tmp}/$NAME.XXXXXX")" || { say "ERROR: mktemp failed"; exit 1; }; }

# Run "$@" with a time limit (macOS has no timeout(1)); stdin is /dev/null.
# Returns the command's status, or 143/137 when it was killed. CUR_PID is the
# command in flight, for on_exit. Background children get no fd 3/4, so a
# leftover one cannot hold the terminal or the log open.
CUR_PID=""
with_timeout() {
  local secs="$1" pid watcher rc=0
  shift
  "$@" < /dev/null 3>&- 4>&- &
  pid=$!
  CUR_PID="$pid"
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null && sleep 3 && kill -KILL "$pid" 2>/dev/null ) < /dev/null > /dev/null 2>&1 3>&- 4>&- &
  watcher=$!
  wait "$pid" || rc=$?
  CUR_PID=""
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  return "$rc"
}

# json <file> <JavaScript expression over the parsed JSON `j`>: prints the
# value; '' for null, undefined or an unparsable file; objects as JSON.
json() {
  "$JSON_ENGINE" -l JavaScript - "$1" "$2" 2>/dev/null <<'JS'
function run(argv) {
  ObjC.import('Foundation');
  var s = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
  if (s.isNil()) return '';
  var j; try { j = JSON.parse(s.js); } catch (e) { return ''; }
  var v; try { v = (new Function('j', 'return (' + argv[1] + ');'))(j); } catch (e) { return ''; }
  if (v === null || v === undefined) return '';
  return (typeof v === 'object') ? JSON.stringify(v) : String(v);
}
JS
}
json_selftest() {
  printf '{"ok":"yes"}' > "$TMP/selftest.json"
  [ "$(json "$TMP/selftest.json" 'j.ok')" = yes ] \
    || fail "setup" "cannot parse JSON with $JSON_ENGINE -l JavaScript; nothing can be checked"
}

# The two backends. daemon: the Homebrew CLI on the daemon's socket (an
# explicit --socket makes it use that socket only). app: the GUI app's binary
# as a CLI, run as the GUI user.
CLI=()
cli() {
  case "$1" in
    daemon) CLI=("$TS_CLI" --socket="$SOCKET") ;;
    app)    CLI=(sudo -u "$GUI_USER" -H env TAILSCALE_BE_CLI=1 "$APP_BIN") ;;
  esac
}
ts() {   # ts <daemon|app> <args...>: one CLI call, bounded by CMD_TIMEOUT
  local stack="$1"; shift
  if [ "$stack" = daemon ] && ! formula_ok; then echo "no tailscale formula" >&2; return 127; fi
  if [ "$stack" = app ] && [ ! -x "$APP_BIN" ]; then echo "no GUI app" >&2; return 127; fi
  cli "$stack"
  with_timeout "$CMD_TIMEOUT" "${CLI[@]}" "$@"
}

JS_STATUS='(function(){var ip="";(j.TailscaleIPs||[]).forEach(function(a){if(!ip&&a.indexOf(".")>0)ip=a;});
return ["state="+(j.BackendState||""),"auth="+(j.AuthURL||""),"dns="+((j.Self&&j.Self.DNSName)||"").replace(/\.$/,""),"ip4="+ip].join("\n");})()'
ST_STATE=""; ST_AUTH=""; ST_DNS=""; ST_IP4=""
read_status() {   # read_status <daemon|app>: sets ST_*; status 1 when the backend does not answer
  local out
  ST_STATE=""; ST_AUTH=""; ST_DNS=""; ST_IP4=""
  ts "$1" status --json > "$TMP/status.json" 2> "$TMP/status.err" || true
  out="$(json "$TMP/status.json" "$JS_STATUS")"
  ST_STATE="$(printf '%s\n' "$out" | sed -n 's/^state=//p')"
  ST_AUTH="$(printf '%s\n' "$out" | sed -n 's/^auth=//p')"
  ST_DNS="$(printf '%s\n' "$out" | sed -n 's/^dns=//p')"
  ST_IP4="$(printf '%s\n' "$out" | sed -n 's/^ip4=//p')"
  [ -n "$ST_STATE" ]
}
wait_backend() {  # wait_backend <stack>: until it answers (any state), up to BACKEND_TIMEOUT
  local deadline=$(( $(date +%s) + BACKEND_TIMEOUT ))
  until read_status "$1"; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep "$POLL"
  done
}

# Prefs, normalised to key=value lines (empty = null, false or an empty list).
JS_PREFS_FN='function(K){return K.map(function(k){var v=j[k];
if(v===null||v===undefined||v===false||(Array.isArray(v)&&!v.length))v="";else if(Array.isArray(v))v=v.join(",");
return k+"="+v;}).join("\n");}'
prefs_values() {  # prefs_values <stack> <key...>; status 1 if unreadable
  local stack="$1" keys="" k got
  shift
  ts "$stack" debug prefs > "$TMP/prefs.json" 2> "$TMP/prefs.err" || return 1
  for k in "$@"; do keys="$keys\"$k\","; done
  got="$(json "$TMP/prefs.json" "($JS_PREFS_FN)([${keys%,}])")"
  rm -f "$TMP/prefs.json"   # holds node key fields (redacted by the CLI, still not worth keeping)
  [ -n "$got" ] || return 1
  printf '%s\n' "$got"
}
PREF_DIFF=""
check_prefs() {   # check_prefs <stack> <key=value...>; mismatches go to PREF_DIFF
  local stack="$1" kv got line bad=0 keys=()
  shift
  PREF_DIFF=""
  for kv in "$@"; do keys+=("${kv%%=*}"); done
  got="$(prefs_values "$stack" "${keys[@]}")" || { PREF_DIFF=" cannot read the prefs"; return 1; }
  for kv in "$@"; do
    line="$(printf '%s\n' "$got" | grep -m 1 "^${kv%%=*}=" || true)"
    if [ "$line" != "$kv" ]; then PREF_DIFF="$PREF_DIFF ${kv%%=*}: want '${kv#*=}' have '${line#*=}';"; bad=1; fi
  done
  return "$bad"
}
daemon_expect() {  # the prefs the daemon must end up with
  # shellcheck disable=SC2086  # EXPECT_PREFS is a word list
  printf '%s\n' $EXPECT_PREFS "OperatorUser=$GUI_USER"
  [ -z "$HOST" ] || printf '%s\n' "Hostname=$HOST"
}
record_gui_prefs() {  # save the app's non-secret prefs for the rollback
  local v
  # shellcheck disable=SC2086  # GUI_PREF_KEYS is a word list
  v="$(prefs_values app $GUI_PREF_KEYS)" || return 1
  printf '%s\n' "$v" > "$GUI_PREFS_FILE.tmp" && mv "$GUI_PREFS_FILE.tmp" "$GUI_PREFS_FILE" || return 1
  chown "$GUI_USER" "$GUI_PREFS_FILE" 2>/dev/null || true
  show_lines "GUI app prefs recorded in $GUI_PREFS_FILE (the rollback checks them):" "$v"
}
recorded_up_flags() { # recorded_up_flags <prefs file>: `up --reset` flags that restore those prefs
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      Hostname)        [ -z "$v" ] || echo "--hostname=$v" ;;
      RouteAll)        if [ "$v" = true ]; then echo --accept-routes; else echo --accept-routes=false; fi ;;
      CorpDNS)         if [ "$v" = true ]; then echo --accept-dns; else echo --accept-dns=false; fi ;;
      ShieldsUp)       [ "$v" != true ] || echo --shields-up ;;
      AdvertiseTags)   [ -z "$v" ] || echo "--advertise-tags=$v" ;;
      AdvertiseRoutes) [ -z "$v" ] || echo "--advertise-routes=$v" ;;
      RunSSH)          [ "$v" != true ] || echo --ssh ;;
    esac
  done < "$1"
}

# Serve config, normalised to sorted lines:
#   tcp <port> https                      a TLS-terminating listener
#   <dns name>:<port> <path> <target> <funnel|tailnet>
JS_SERVE='(function(){var o=[],w=j.Web||{},f=j.AllowFunnel||{},t=j.TCP||{};
Object.keys(t).forEach(function(p){o.push("tcp "+p+" "+(t[p]&&t[p].HTTPS?"https":JSON.stringify(t[p])));});
Object.keys(w).forEach(function(hp){var h=(w[hp]&&w[hp].Handlers)||{};Object.keys(h).forEach(function(m){var x=h[m]||{};
o.push(hp+" "+m+" "+(x.Proxy||x.Path||x.Text||JSON.stringify(x))+" "+(f[hp]?"funnel":"tailnet"));});});
Object.keys(f).forEach(function(hp){if(f[hp]&&!w[hp])o.push(hp+" (no-handler) - funnel");});
if(j.Services&&Object.keys(j.Services).length)o.push("services "+Object.keys(j.Services).join(","));
return o.join("\n");})()'
mounts() { printf '%s\n' "$SERVE_MOUNTS" | awk 'NF == 4 && $1 !~ /^#/'; }
want_serve() {    # want_serve <dns name>
  local port path target mode
  while read -r port path target mode; do
    printf 'tcp %s https\n%s:%s %s %s %s\n' "$port" "$1" "$port" "$path" "$target" "$mode"
  done <<EOF | LC_ALL=C sort
$(mounts)
EOF
}
HAVE_SERVE=""
read_serve() {    # read_serve <stack> [copy-to-file]: sets HAVE_SERVE; status 1 if unreadable
  HAVE_SERVE=""
  ts "$1" serve status --json > "$TMP/serve.json" 2> "$TMP/serve.err" || return 1
  [ "$(json "$TMP/serve.json" 'typeof j')" = object ] || return 1
  [ -z "${2:-}" ] || cp "$TMP/serve.json" "$2"
  HAVE_SERVE="$(json "$TMP/serve.json" "$JS_SERVE" | LC_ALL=C sort)"
}
show_lines() {    # show_lines <title> <lines>
  local l
  say "$1"
  if [ -z "$2" ]; then say "    (none)"; return; fi
  while IFS= read -r l; do say "    $l"; done <<EOF
$2
EOF
}
serve_matches() { # serve_matches <stack>: status 0 when the node's mounts are the configured ones
  read_status "$1" && [ -n "$ST_DNS" ] || return 1
  read_serve "$1" || return 1
  [ "$HAVE_SERVE" = "$(want_serve "$ST_DNS")" ]
}
converge_serve() { # converge_serve <stack>: re-create the mounts when they differ
  local stack="$1" want port path target mode cmd args
  read_status "$stack" && [ -n "$ST_DNS" ] || fail "serve" "the node has no DNS name yet (state ${ST_STATE:-not answering})"
  want="$(want_serve "$ST_DNS")"
  read_serve "$stack" || fail "serve" "cannot read the serve config: $(tail -n 2 "$TMP/serve.err")"
  if [ "$HAVE_SERVE" = "$want" ]; then say "serve/funnel: as configured for $ST_DNS"; return 0; fi
  show_lines "serve/funnel now:" "$HAVE_SERVE"
  show_lines "serve/funnel wanted:" "$want"
  CHANGED=1
  say "serve/funnel: tailscale serve reset"
  ts "$stack" serve reset > "$TMP/serve.out" 2>&1 || fail "serve" "serve reset: $(tail -n 3 "$TMP/serve.out")"
  while read -r port path target mode; do
    args=(--bg --yes --https="$port")
    [ "$path" = / ] || args+=(--set-path="$path")
    if [ "$mode" = funnel ]; then cmd=funnel; else cmd=serve; fi
    say "serve/funnel: tailscale $cmd ${args[*]} $target"
    ts "$stack" "$cmd" "${args[@]}" "$target" > "$TMP/serve.out" 2>&1 \
      || fail "serve" "tailscale $cmd for port $port: $(tail -n 5 "$TMP/serve.out" | tr '\n' ' ')"
  done <<EOF
$(mounts)
EOF
  read_serve "$stack" || fail "serve" "cannot read the serve config back"
  if [ "$HAVE_SERVE" != "$want" ]; then
    show_lines "serve/funnel after re-creating:" "$HAVE_SERVE"
    fail "serve" "the serve config still differs (Funnel or HTTPS not enabled for this node? the CLI output was: $(tr '\n' ' ' < "$TMP/serve.out" | cut -c 1-300))"
  fi
  say "serve/funnel: re-created for $ST_DNS"
}

# `up` in the background; show the login URL; wait for Running. No --timeout:
# any flag, --timeout included, turns a bare `up` into one that re-checks
# every pref; this loop enforces the deadline itself. UP_PID is for on_exit.
UP_PID=""
login_banner() {  # login_banner <url> <deadline epoch>
  say "=================================================================="
  say "LOGIN NEEDED: open this URL in a browser and approve the node:"
  say ""
  say "    $1"
  say ""
  say "waiting until $(date -r "$2" '+%H:%M:%S') (${LOGIN_TIMEOUT}s)"
  say "=================================================================="
}
bring_up() {      # bring_up <stack> [up flags...]
  local stack="$1" out rc deadline url shown="" approval_said=0 exited=0 n
  shift
  out="$TMP/up.out"
  say "tailscale up${*:+ $*}"
  cli "$stack"
  "${CLI[@]}" up ${@+"$@"} > "$out" 2>&1 < /dev/null 3>&- 4>&- &
  UP_PID=$!
  deadline=$(( $(date +%s) + LOGIN_TIMEOUT ))
  while :; do
    if read_status "$stack" && [ "$ST_STATE" = Running ]; then break; fi
    url="$ST_AUTH"
    [ -n "$url" ] || url="$(awk '/To authenticate, visit:/ { f = 1; next } f && NF { print $1; exit }' "$out")"
    if [ -n "$url" ] && [ "$url" != "$shown" ]; then login_banner "$url" "$deadline"; shown="$url"; fi
    if [ "$ST_STATE" = NeedsMachineAuth ] && [ "$approval_said" = 0 ]; then
      say "the node is logged in but waits for device approval: approve it in the admin console (Machines)"
      approval_said=1
    fi
    if [ "$exited" = 0 ] && ! kill -0 "$UP_PID" 2>/dev/null; then
      rc=0; wait "$UP_PID" || rc=$?
      exited=1; UP_PID=""
      [ "$rc" = 0 ] || fail "up" "tailscale up exited $rc before Running: $(tail -n 5 "$out" | tr '\n' ' ')"
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      fail "up" "not Running after ${LOGIN_TIMEOUT}s (state ${ST_STATE:-not answering}); login URL ${shown:-never seen}"
    fi
    sleep "$POLL"
  done
  if [ "$exited" = 0 ]; then     # up exits by itself once Running; give it a moment
    n=0
    while kill -0 "$UP_PID" 2>/dev/null && [ "$n" -lt 15 ]; do sleep 1; n=$((n + 1)); done
    kill "$UP_PID" 2>/dev/null || true
    wait "$UP_PID" 2>/dev/null || true
    UP_PID=""
  fi
  say "backend Running: ${ST_DNS:-?} ${ST_IP4:-?}"
}

# GUI app.
gui_vpn() {       # state of the app's VPN service (Connected, Disconnected, ...), '' when none
  scutil --nc list 2>/dev/null | awk -v id="[VPN:$APP_ID]" \
    'index($0, id) { if (match($0, /\([A-Za-z ]+\)/)) print substr($0, RSTART + 1, RLENGTH - 2); exit }'
}
gui_vpn_id() {
  scutil --nc list 2>/dev/null | awk -v id="[VPN:$APP_ID]" \
    'index($0, id) { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-Fa-f]+-[0-9A-Fa-f]+-/) { print $i; exit } }'
}
ts_vpns() {       # every Tailscale VPN service, any variant: "<state> [VPN:<id>]" per line
  scutil --nc list 2>/dev/null | awk 'index($0, "[VPN:io.tailscale.") {
    st = "?"; if (match($0, /\([A-Za-z ]+\)/)) st = substr($0, RSTART + 1, RLENGTH - 2); print st " " $NF }'
}
ts_gui_procs() { pgrep -x Tailscale 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }     # the GUI app, any user
ts_ne_procs() { pgrep -f 'io[.]tailscale[.]ipn[.].*network-extension|IPNExtension' 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
vpn_is_up() { case "$1" in Connected|Connecting|Reasserting) return 0 ;; *) return 1 ;; esac; }
start_on_login() { as_user defaults read "$APP_ID" TailscaleStartOnLogin 2>/dev/null || true; }
set_start_on_login() { as_user defaults write "$APP_ID" TailscaleStartOnLogin -bool "$1"; }
gui_pids() { pgrep -U "$GUI_UID" -x Tailscale 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
app_version() { /usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist" 2>/dev/null || echo "?"; }
gui_session() { launchctl print "gui/$GUI_UID" > /dev/null 2>&1; }
launch_app() { launchctl asuser "$GUI_UID" sudo -u "$GUI_USER" open -b "$APP_ID" > /dev/null 2>&1; }
app_wantrunning() { # 'true', '' (off) or 'unknown'
  local v
  v="$(prefs_values app WantRunning)" || { echo unknown; return; }
  printf '%s\n' "${v#WantRunning=}"
}
helper_state() {  # disabled | enabled | unset (no override) for the login-item helper
  launchctl print-disabled "gui/$GUI_UID" 2>/dev/null | awk -v l="\"$HELPER_LABEL\"" '
    $1 == l { s = ($3 == "disabled" || $3 == "true") ? "disabled" : "enabled" }
    END { print (s == "" ? "unset" : s) }'
}
wait_gui_down() { # until the app's backend is not Running/Starting and its VPN service is down
  local deadline=$(( $(date +%s) + BACKEND_TIMEOUT )) st
  while :; do
    st=""; if read_status app; then st="$ST_STATE"; fi
    case "$st" in Running|Starting) ;; *) vpn_is_up "$(gui_vpn)" || return 0 ;; esac
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep "$POLL"
  done
}

# Daemon.
daemon_job() { launchctl print "system/$DAEMON_LABEL" 2>/dev/null; }
daemon_loaded() { daemon_job > /dev/null; }
daemon_pid() { daemon_job | awk '$1 == "pid" && $2 == "=" { print $3; exit }'; }
daemon_installed() { [ -f "$DAEMON_PLIST" ] && daemon_loaded; }
run_at_load() { /usr/bin/plutil -extract RunAtLoad raw -o - "$DAEMON_PLIST" 2>/dev/null || true; }
bin_version() { [ -x "$1" ] && "$1" --version 2>/dev/null | head -n 1; }

# Processes other than Tailscale's own (tailscaled, the GUI app, its network
# extension) with a TCP listening socket or a UDP socket whose local address
# is a tailnet address (100.64.0.0/10 or fd7a:115c:a1e0::/48). Status 2 when
# lsof lists no TCP listener, 3 when it lists no UDP socket: neither happens
# on a working host, so the check fails closed.
bound_listeners() {
  local tcp udp
  tcp="$(with_timeout "$CMD_TIMEOUT" lsof -nP +c 0 -iTCP -sTCP:LISTEN -F pcn 2>/dev/null)"
  [ -n "$tcp" ] || return 2
  udp="$(with_timeout "$CMD_TIMEOUT" lsof -nP +c 0 -iUDP -F pcn 2>/dev/null)"
  [ -n "$udp" ] || return 3
  printf '%s\n%s\n' "$tcp" "$udp" | awk '
    /^p/ { pid = substr($0, 2); next }
    /^c/ { cmd = substr($0, 2); next }
    /^n/ {
      n = substr($0, 2); a = n; sub(/->.*/, "", a)
      if (a ~ /^\[/) { a = substr(a, 2); sub(/\].*/, "", a) } else { sub(/:[^:]*$/, "", a) }
      a = tolower(a)
      if (cmd ~ /^(io\.tailscale\..*|tailscaled|Tailscale|IPNExtension)$/) next
      if (a ~ /^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\./ || a ~ /^fd7a:115c:a1e0:/) print cmd " pid " pid " " n
    }' | sort -u
}

# Is the starting point known-good for a first cutover? Sets START_PROBLEM
# ('' = yes) and START_ADVICE.
START_PROBLEM=""; START_ADVICE=""; LISTENERS=""
check_start() {
  local rc=0
  START_PROBLEM=""; START_ADVICE=""; LISTENERS=""
  local known_good="The starting point must be known-good: bring the tailnet up on the GUI app first (open Tailscale in $GUI_USER's session and connect, or: sudo -u $GUI_USER TAILSCALE_BE_CLI=1 $APP_BIN up). If an earlier cutover stopped part-way, finish going back with: $ROLLBACK_CMD"
  if [ -x "$APP_BIN" ]; then
    if ! read_status app; then
      START_PROBLEM="the GUI app is installed but its backend does not answer"
      START_ADVICE="$known_good"; return
    fi
    if [ "$ST_STATE" != Running ] || [ -z "$ST_IP4" ]; then
      START_PROBLEM="the GUI app's backend is ${ST_STATE}${ST_IP4:+ ($ST_IP4)}, not Running with a tailnet IPv4"
      START_ADVICE="$known_good"; return
    fi
  else
    local vpns procs
    vpns="$(ts_vpns | tr '\n' ' ' | sed 's/ $//')"; procs="$(ts_gui_procs) $(ts_ne_procs)"; procs="${procs# }"; procs="${procs% }"
    if [ -n "$vpns" ] || [ -n "$procs" ]; then
      START_PROBLEM="there is no GUI app at $APP, but Tailscale is present (VPN services: ${vpns:-none}; GUI or network-extension pids: ${procs:-none})"
      START_ADVICE="Point the script at the installed app (sudo TS_CUTOVER_APP=<path to Tailscale.app> bash …), or remove the leftover VPN configuration once nothing runs. The cutover does not put a second stack next to one it cannot control."
      return
    fi
  fi
  LISTENERS="$(bound_listeners)" || rc=$?
  if [ "$rc" = 2 ] || [ "$rc" = 3 ]; then
    START_PROBLEM="cannot list the host's sockets (lsof returned no $([ "$rc" = 2 ] && echo 'TCP listener' || echo 'UDP socket') within ${CMD_TIMEOUT}s)"
    START_ADVICE="Check that lsof works as root; the cutover does not start blind."; return
  fi
  if [ -n "$LISTENERS" ]; then
    START_PROBLEM="processes bind a tailnet address and would fail while it is gone"
    START_ADVICE="Re-bind them to 127.0.0.1 or the wildcard address first."
  fi
}

# ── run bookkeeping ────────────────────────────────────────────
ensure_log_dir() {
  [ -d "$LOG_DIR" ] || as_user mkdir -p "$LOG_DIR" || mkdir -p "$LOG_DIR" || { say "ERROR: cannot create $LOG_DIR"; exit 1; }
}
LOCK_HELD=0
acquire_lock() {
  local holder tries=0
  until mkdir "$LOCK" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -le 30 ] || fail "lock" "cannot take the lock $LOCK"
    holder="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if [ -z "$holder" ] && [ "$tries" -le 10 ]; then sleep 0.2; continue; fi   # its owner may be writing the pid
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
      fail "lock" "another run (pid $holder) is going; see $LOG_DIR/last-run.log"
    fi
    rm -rf "$LOCK"
  done
  printf '%s\n' "$$" > "$LOCK/pid.tmp" && mv "$LOCK/pid.tmp" "$LOCK/pid"
  LOCK_HELD=1
}
STARTED=0
report_end() {    # report_end <rc>: state first, then how to go back, then what failed
  local rc="$1" app_st dmn_st
  CMD_TIMEOUT=10
  if [ ! -x "$APP_BIN" ]; then app_st="not installed"; elif read_status app; then app_st="$ST_STATE"; else app_st="not answering"; fi
  if formula_ok && read_status daemon; then dmn_st="$ST_STATE"
  elif daemon_loaded; then dmn_st="loaded, not answering"
  elif [ -f "$DAEMON_PLIST" ]; then dmn_st="installed, not loaded"
  else dmn_st="not installed"; fi
  if [ "$app_st" != Running ] && [ "$dmn_st" != Running ]; then
    say "!!! Tailscale is DOWN on this host now: neither the GUI app ($app_st) nor the daemon ($dmn_st) is Running. No tailnet, Funnel is off.$([ "$CHANGED" = 1 ] || echo ' (It was down before this run.)')"
  else
    say "state now: GUI app $app_st; daemon $dmn_st"
  fi
  if [ "$rc" = 0 ]; then
    [ "$MODE" != cutover ] || say "to go back to the GUI app: $ROLLBACK_CMD"
    return
  fi
  if [ "$CHANGED" = 1 ]; then
    if [ "$MODE" = cutover ] && ! daemon_installed; then
      say "to go back to the GUI app: $ROLLBACK_CMD"
      say "(run it before any new attempt: the cutover starts only from a known-good GUI app, and a re-run now refuses)"
    elif [ "$MODE" = cutover ]; then
      say "to go back to the GUI app: $ROLLBACK_CMD"
      say "or fix the cause and run the same command again: sudo bash $SCRIPT_ABS ${ORIG_ARGS[*]+${ORIG_ARGS[*]}}"
    else
      say "to try the rollback again: $ROLLBACK_CMD"
    fi
  else
    say "nothing on the host was changed."
  fi
}
on_exit() {
  local rc=$? n
  trap ':' INT TERM   # no re-entry; a no-op handler (unlike '') is not inherited by children
  if [ -n "$UP_PID" ]; then kill "$UP_PID" 2>/dev/null || true; wait "$UP_PID" 2>/dev/null || true; fi
  if [ -n "$CUR_PID" ] && kill -0 "$CUR_PID" 2>/dev/null; then
    say "waiting up to ${CMD_TIMEOUT}s for the interrupted command (pid $CUR_PID) to finish"
    n=0
    while kill -0 "$CUR_PID" 2>/dev/null && [ "$n" -lt "$CMD_TIMEOUT" ]; do sleep 1; n=$((n + 1)); done
  fi
  if [ "$STARTED" = 1 ] && [ "$MODE" != preflight ]; then
    report_end "$rc"
  elif [ "$rc" != 0 ] && [ "$MODE" != preflight ]; then
    say "nothing on the host was changed."
  fi
  if [ -n "$FAIL_STEP" ]; then say "FAILED at $FAIL_STEP: $FAIL_MSG"
  elif [ "$rc" -ge 128 ]; then say "stopped by a signal (exit $rc)"; fi
  [ -z "$TMP" ] || rm -rf "$TMP"
  printf '%s %s exit %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MODE" "$rc" >> "$LOG_DIR/history.log" 2>/dev/null || true
  chown "$GUI_USER" "$LOG_DIR/history.log" 2>/dev/null || true
  say "finished: exit $rc"
  if [ "$LOCK_HELD" = 1 ]; then rm -rf "$LOCK" 2>/dev/null || true; fi
  exit "$rc"
}
begin_run() {     # begin_run <log file name>
  trap '' PIPE HUP              # a dropped SSH session must not stop the run
  trap on_exit EXIT
  trap 'exit 130' INT; trap 'exit 143' TERM
  ensure_log_dir
  [ "$MODE" = preflight ] || acquire_lock
  exec 4> "$LOG_DIR/$1"         # truncated only now, with the lock held
  LOG_OPEN=1
  chown "$GUI_USER" "$LOG_DIR/$1" 2>/dev/null || true
  make_tmp
  STARTED=1
  say "$MODE started $(date -u +%Y-%m-%dT%H:%M:%SZ) pid $$ (user $GUI_USER, console ${CONSOLE_USER:-none})"
}

# ── preflight ──────────────────────────────────────────────────
run_preflight() {
  local problems=0 active="" dump vpn sol shim job wr sess
  say "preflight: reads only, changes nothing (except the records in $LOG_DIR)"
  if gui_session; then sess=yes; else sess=no; fi
  say "macOS $(sw_vers -productVersion 2>/dev/null || echo '?'); GUI user $GUI_USER (uid $GUI_UID); console user ${CONSOLE_USER:-none}; GUI session $sess"
  json_selftest

  if formula_ok; then
    say "formula: $TS_CLI ($(bin_version "$TS_CLI")) and $TSD"
  else
    problems=$((problems + 1))
    say "NOT READY: the Homebrew tailscale formula is missing (looked for ${BREW_PREFIX:-<no Homebrew found>}/opt/tailscale/bin/tailscale and tailscaled)."
    say "  Install it as $GUI_USER, not as root (brew refuses root), well before the window:"
    say "    eval \"\$(${BREW:-brew} shellenv)\"; brew install tailscale"
    say "  Where Homebrew has no bottle for this macOS version (none for macOS 14 Sonoma), it builds Go and tailscale from source: slow."
  fi

  if [ -x "$APP_BIN" ]; then
    vpn="$(gui_vpn)"; sol="$(start_on_login)"
    if read_status app; then
      say "GUI app: $APP $(app_version); backend $ST_STATE; node ${ST_DNS:-?} ${ST_IP4:-no IPv4}"
      [ "$ST_STATE" != Running ] || active=app
      wr="$(app_wantrunning)"
      say "GUI app: WantRunning ${wr:-off}"
      record_gui_prefs || say "WARNING: cannot read the GUI app's prefs; nothing recorded"
    else
      say "GUI app: $APP $(app_version); backend not answering"
    fi
    say "GUI app: VPN service ${vpn:-none}; TailscaleStartOnLogin ${sol:-unset}; app process $(gui_pids)"
    if [ -n "$HELPER_LABEL" ]; then say "GUI app: login-item helper $HELPER_LABEL: $(helper_state)"; else say "GUI app: no login-item helper in the bundle"; fi
    if launchctl print "system/$SENTINEL_LABEL" > /dev/null 2>&1; then
      problems=$((problems + 1))
      say "NOT READY: the app's Always-On helper ($SENTINEL_LABEL) is loaded; an MDM AlwaysOn policy would restart the app. Turn that policy off first."
    fi
  else
    say "GUI app: not installed"
  fi
  if [ -L /usr/local/bin/tailscale ] || [ -e /usr/local/bin/tailscale ]; then
    shim="$(readlink /usr/local/bin/tailscale 2>/dev/null || echo 'a file')"
    say "note: /usr/local/bin/tailscale is $shim. Callers that find it on PATH reach the GUI app, not the daemon."
  fi

  if [ -f "$DAEMON_PLIST" ]; then
    if daemon_loaded; then job="loaded, pid $(daemon_pid)"; else job="not loaded"; fi
    say "daemon: $DAEMON_PLIST present (RunAtLoad $(run_at_load)); launchd job $job"
    say "daemon: $DAEMON_BIN $(bin_version "$DAEMON_BIN" || echo missing); formula tailscaled $(bin_version "$TSD" || echo missing)"
  else
    say "daemon: not installed"
  fi
  [ ! -f "$STATE_FILE" ] || say "daemon: state file $STATE_FILE exists (an earlier daemon node; it is reused)"
  if formula_ok && read_status daemon; then
    say "daemon: backend $ST_STATE; node ${ST_DNS:-?} ${ST_IP4:-no IPv4}"
    [ "$ST_STATE" != Running ] || active=daemon
  fi

  if [ -n "$active" ]; then
    dump="$LOG_DIR/serve-config-$(date -u +%Y%m%dT%H%M%SZ).json"
    if read_serve "$active" "$dump"; then
      chown "$GUI_USER" "$dump" 2>/dev/null || true
      say "serve config of the $active backend saved to $dump"
      read_status "$active" || true
      if [ "$HAVE_SERVE" = "$(want_serve "$ST_DNS")" ]; then
        say "serve/funnel: as configured (SERVE_MOUNTS)"
      else
        show_lines "serve/funnel now (differs from SERVE_MOUNTS; the cutover re-creates it):" "$HAVE_SERVE"
      fi
    else
      say "WARNING: cannot read the serve config of the $active backend: $(tail -n 1 "$TMP/serve.err")"
    fi
  else
    say "no backend is Running: no serve config to save"
  fi

  if [ "$active" = daemon ]; then
    say "already cut over: the daemon is Running. Re-run the cutover to verify:"
    say "    sudo bash $SCRIPT_ABS --detach"
  elif daemon_installed; then
    problems=$((problems + 1))
    say "NOT READY: a cutover stopped part-way (the daemon is installed but not Running). Run the cutover command again to continue, or go back: $ROLLBACK_CMD"
  elif [ -f "$DAEMON_PLIST" ]; then
    problems=$((problems + 1))
    say "NOT READY: $DAEMON_PLIST exists but launchd has not loaded it (a partial install?). Clear it first: $ROLLBACK_CMD"
  else
    check_start
    if [ -z "$START_PROBLEM" ]; then
      say "starting point: GUI app Running on the tailnet; nothing but Tailscale binds a tailnet address (100.64.0.0/10, fd7a:115c:a1e0::/48; TCP listeners and UDP)"
    else
      problems=$((problems + 1))
      say "NOT READY: $START_PROBLEM."
      [ -z "$LISTENERS" ] || show_lines "  bound to a tailnet address:" "$LISTENERS"
      say "  $START_ADVICE"
    fi
  fi

  if [ "$problems" = 0 ]; then
    [ "$active" = daemon ] || { say "READY. Next:"; say "    sudo bash $SCRIPT_ABS --hostname <name> --detach"; }
    return 0
  fi
  say "NOT READY: $problems problem(s) above"
  return 1
}

# ── cutover ────────────────────────────────────────────────────
step_gui_off() {
  local st="" vpn pids n id wr="unknown" answers=0
  if [ ! -x "$APP_BIN" ]; then
    vpn="$(ts_vpns | awk '$1 ~ /^(Connected|Connecting|Reasserting)$/' | tr '\n' ' ')"; pids="$(ts_gui_procs)"
    if [ -n "$vpn" ] || [ -n "$pids" ]; then
      fail "gui down" "there is no GUI app at $APP, but a Tailscale VPN is up (${vpn:-none}) or a Tailscale GUI runs (pids ${pids:-none}); point TS_CUTOVER_APP at the app"
    fi
    say "GUI app: not installed at $APP; no Tailscale VPN up and no Tailscale GUI running"
    return 0
  fi
  vpn="$(gui_vpn)"
  if read_status app; then st="$ST_STATE"; answers=1; wr="$(app_wantrunning)"; fi
  say "GUI app: backend ${st:-not answering}; WantRunning ${wr:-off}; VPN service ${vpn:-none}"
  if [ "$answers" = 1 ] && { [ "$st" != Stopped ] || [ "$wr" != "" ] || vpn_is_up "$vpn"; } \
     || { [ "$answers" = 0 ] && vpn_is_up "$vpn"; }; then
    [ -z "$ST_IP4" ] || say "GUI app: its node was ${ST_DNS:-?} $ST_IP4 (the IPv4 to give the new node in the admin console)"
    CHANGED=1
    say "GUI app: tailscale down"
    ts app down > "$TMP/down.out" 2>&1 || say "GUI app: down said: $(tail -n 3 "$TMP/down.out" | tr '\n' ' ')"
    if ! wait_gui_down; then
      id="$(gui_vpn_id)"
      say "GUI app: VPN service still $(gui_vpn) after ${BACKEND_TIMEOUT}s; scutil --nc stop ${id:-?}"
      [ -z "$id" ] || scutil --nc stop "$id" > /dev/null 2>&1 || true
      wait_gui_down || fail "gui down" "the GUI app is still connected (backend ${ST_STATE:-?}, VPN $(gui_vpn)); installing the daemon now would put two Tailscale stacks on one host"
    fi
    if [ "$answers" = 1 ]; then
      wr="$(app_wantrunning)"
      [ -z "$wr" ] || fail "gui down" "the GUI app's WantRunning is still '$wr' after down"
    fi
    say "GUI app: disconnected (backend ${ST_STATE:-not answering}, VPN service $(gui_vpn))"
  fi
  if [ "$(start_on_login)" != 0 ]; then
    CHANGED=1
    set_start_on_login false
    [ "$(start_on_login)" = 0 ] || fail "gui login item" "TailscaleStartOnLogin did not turn off (domain $APP_ID, user $GUI_USER)"
    say "GUI app: start on login off"
  else
    say "GUI app: start on login already off"
  fi
  if [ -n "$HELPER_LABEL" ]; then
    if [ "$(helper_state)" != disabled ]; then
      CHANGED=1
      launchctl disable "gui/$GUI_UID/$HELPER_LABEL" > /dev/null 2>&1 || true
      [ "$(helper_state)" = disabled ] || fail "gui login item" "launchctl disable gui/$GUI_UID/$HELPER_LABEL did not take"
      say "GUI app: login-item helper $HELPER_LABEL disabled for $GUI_USER"
    else
      say "GUI app: login-item helper already disabled"
    fi
  fi
  pids="$(gui_pids)"
  if [ -n "$pids" ]; then
    CHANGED=1
    say "GUI app: quitting (pid $pids)"
    pkill -TERM -U "$GUI_UID" -x Tailscale 2>/dev/null || true
    n=0
    while [ -n "$(gui_pids)" ] && [ "$n" -lt 10 ]; do sleep 1; n=$((n + 1)); done
    [ -z "$(gui_pids)" ] || say "WARNING: the app is still running (pid $(gui_pids)); harmless while disconnected. Quit it from the menu bar."
  fi
}
step_daemon() {
  if daemon_installed && read_status daemon; then say "daemon: installed (pid $(daemon_pid)); backend $ST_STATE"; return 0; fi
  CHANGED=1
  say "daemon: $TSD install-system-daemon"
  with_timeout "$CMD_TIMEOUT" "$TSD" install-system-daemon > "$TMP/install.out" 2>&1 \
    || fail "daemon install" "$(tail -n 5 "$TMP/install.out" | tr '\n' ' ')"
  [ -f "$DAEMON_PLIST" ] || fail "daemon install" "no $DAEMON_PLIST after install-system-daemon"
  daemon_loaded || fail "daemon install" "launchd has no system/$DAEMON_LABEL after install-system-daemon"
  say "daemon: installed $DAEMON_PLIST (RunAtLoad $(run_at_load)), $DAEMON_BIN, pid $(daemon_pid)"
  wait_backend daemon \
    || fail "daemon start" "no answer on $SOCKET within ${BACKEND_TIMEOUT}s; check: sudo launchctl print system/$DAEMON_LABEL"
  say "daemon: answering on $SOCKET; backend $ST_STATE"
}
step_up() {
  local expect=() l
  while IFS= read -r l; do expect+=("$l"); done <<EOF
$(daemon_expect)
EOF
  read_status daemon || fail "up" "the daemon stopped answering on $SOCKET"
  if [ "$ST_STATE" = Running ] && check_prefs daemon "${expect[@]}"; then
    say "daemon: Running with the configured prefs"; return 0
  fi
  [ "$ST_STATE" != Running ] || say "daemon: prefs differ:$PREF_DIFF"
  [ -n "$HOST" ] || fail "up" "the daemon needs 'tailscale up' (state $ST_STATE) but no --hostname was given"
  CHANGED=1
  bring_up daemon --reset "${UP_FLAGS[@]}" --operator="$GUI_USER" --hostname="$HOST"
  check_prefs daemon "${expect[@]}" || fail "up" "prefs after up:$PREF_DIFF"
}
verify_daemon() {
  local bad=0 expect=() vpn l wr
  while IFS= read -r l; do expect+=("$l"); done <<EOF
$(daemon_expect)
EOF
  if read_status daemon && [ "$ST_STATE" = Running ]; then :; else say "verify: backend ${ST_STATE:-not answering}, want Running"; bad=1; fi
  [ -n "$ST_IP4" ] || { say "verify: no tailnet IPv4"; bad=1; }
  check_prefs daemon "${expect[@]}" || { say "verify: prefs:$PREF_DIFF"; bad=1; }
  serve_matches daemon || { show_lines "verify: serve/funnel differs from SERVE_MOUNTS:" "$HAVE_SERVE"; bad=1; }
  daemon_loaded || { say "verify: launchd has no system/$DAEMON_LABEL"; bad=1; }
  [ "$(run_at_load)" = true ] || { say "verify: $DAEMON_PLIST lacks RunAtLoad"; bad=1; }
  if [ -x "$APP_BIN" ]; then
    vpn="$(gui_vpn)"
    ! vpn_is_up "$vpn" || { say "verify: the GUI app's VPN service is $vpn"; bad=1; }
    [ "$(start_on_login)" = 0 ] || { say "verify: the GUI app still starts on login"; bad=1; }
    if [ -n "$HELPER_LABEL" ] && [ "$(helper_state)" != disabled ]; then say "verify: the login-item helper $HELPER_LABEL is not disabled"; bad=1; fi
    if read_status app; then
      wr="$(app_wantrunning)"
      [ -z "$wr" ] || { say "verify: the GUI app's WantRunning is '$wr'"; bad=1; }
    else
      say "GUI app: backend not answering; its WantRunning cannot be read (start on login and the helper are off)"
    fi
  fi
  [ "$bad" = 0 ] || fail "verify" "see the lines above"
  read_status daemon || true
  say "verified: daemon backend Running, node $ST_DNS $ST_IP4; $DAEMON_PLIST has RunAtLoad and launchd has system/$DAEMON_LABEL loaded (that it comes up at boot is proven only by a reboot); prefs and serve/funnel as configured; GUI app disconnected with WantRunning off (when it answers), start on login off, login-item helper disabled"
}
run_cutover() {
  formula_ok || fail "preflight" "the Homebrew tailscale formula is missing; run --preflight for the install command"
  json_selftest
  if ! { daemon_installed && read_status daemon && [ "$ST_STATE" = Running ]; }; then
    [ -n "$HOST" ] || { say "ERROR: --hostname <name> is required until the daemon is Running"; exit 2; }
  fi
  if ! daemon_installed; then    # a first cutover (or a partial one): the starting point must be known-good
    check_start
    if [ -n "$START_PROBLEM" ]; then
      [ -z "$LISTENERS" ] || show_lines "bound to a tailnet address:" "$LISTENERS"
      if [ -n "$LISTENERS" ] && [ "${TS_CUTOVER_IGNORE_BOUND:-0}" = 1 ]; then
        say "WARNING: going ahead anyway (TS_CUTOVER_IGNORE_BOUND=1)"
      else
        fail "preflight" "$START_PROBLEM. $START_ADVICE"
      fi
    fi
    if [ -x "$APP_BIN" ]; then
      record_gui_prefs || fail "preflight" "cannot record the GUI app's prefs in $GUI_PREFS_FILE (the rollback needs them)"
    fi
  fi
  step_gui_off
  step_daemon
  step_up
  converge_serve daemon
  verify_daemon
  say "next, unless done already, in the admin console (docs/RUNBOOK.md, Tailscale daemon): delete the old GUI node, rename this one to the old name, set its IPv4 back to the old address, disable key expiry. Then re-run this command: it moves the serve/funnel mounts to the new name and verifies."
}

# ── rollback ───────────────────────────────────────────────────
run_rollback() {
  local u="" b recorded="" flags=() f src have_exit want_exit
  json_selftest
  [ -x "$APP_BIN" ] || fail "rollback" "the GUI app is not installed at $APP; install the standalone app first"
  if [ -f "$GUI_PREFS_FILE" ]; then recorded=1; else say "WARNING: no record of the GUI app's prefs ($GUI_PREFS_FILE); they cannot be compared"; fi

  # 1. Prove that the app can come back before touching the daemon.
  gui_session || fail "rollback" "$GUI_USER has no GUI session (console: ${CONSOLE_USER:-none}); the app starts only inside one. Log in on the console or over Screen Sharing, then run this again. The daemon was left as it is."
  if [ -z "$(gui_pids)" ]; then
    say "GUI app: launching in $GUI_USER's session (it stays disconnected until 'up')"
    launch_app || say "WARNING: open -b $APP_ID returned an error"
  fi
  wait_backend app \
    || fail "rollback" "the GUI app's backend does not answer within ${BACKEND_TIMEOUT}s. The daemon was left as it is. Open Tailscale in $GUI_USER's session, then run this again."
  if [ "$ST_STATE" = NeedsLogin ] && [ -z "$recorded" ]; then
    fail "rollback" "the app's node needs a login and there is no record of its prefs ($GUI_PREFS_FILE) to restore after it. Run --preflight once (it records them from the app), then run this again. The daemon was left as it is."
  fi
  say "GUI app: backend answers ($ST_STATE); now the daemon can go"

  # 2. Daemon off.
  if [ -f "$DAEMON_PLIST" ] || daemon_loaded || [ -e "$DAEMON_BIN" ]; then
    CHANGED=1
    for b in "$TSD" "$DAEMON_BIN"; do if [ -n "$b" ] && [ -x "$b" ]; then u="$b"; break; fi; done
    if [ -n "$u" ]; then
      say "daemon: $u uninstall-system-daemon"
      with_timeout "$CMD_TIMEOUT" "$u" uninstall-system-daemon > "$TMP/uninstall.out" 2>&1 \
        || say "daemon: uninstall said: $(tail -n 3 "$TMP/uninstall.out" | tr '\n' ' ')"
    fi
    if daemon_loaded; then
      say "daemon: still loaded; launchctl bootout system/$DAEMON_LABEL"
      launchctl bootout "system/$DAEMON_LABEL" > /dev/null 2>&1 || true
    fi
    rm -f "$DAEMON_PLIST"
    ! daemon_loaded || fail "rollback" "launchd still has system/$DAEMON_LABEL"
    if formula_ok; then
      with_timeout "$CMD_TIMEOUT" "$TSD" --cleanup > /dev/null 2>&1 || true
      say "daemon: tailscaled --cleanup (drops DNS and route settings it may have left)"
    fi
    say "daemon: uninstalled (its state file stays: $STATE_FILE)"
  else
    say "daemon: not installed"
  fi

  # 3. App back on.
  if [ -n "$HELPER_LABEL" ] && [ "$(helper_state)" = disabled ]; then
    CHANGED=1
    launchctl enable "gui/$GUI_UID/$HELPER_LABEL" > /dev/null 2>&1 || true
    [ "$(helper_state)" != disabled ] || fail "rollback" "launchctl enable gui/$GUI_UID/$HELPER_LABEL did not take"
    say "GUI app: login-item helper $HELPER_LABEL enabled"
  fi
  if [ "$(start_on_login)" != 1 ]; then
    CHANGED=1
    set_start_on_login true
    [ "$(start_on_login)" = 1 ] || fail "rollback" "TailscaleStartOnLogin did not turn on"
    say "GUI app: start on login on"
  fi
  read_status app || fail "rollback" "the GUI app's backend stopped answering"
  if [ "$ST_STATE" = Running ]; then
    say "GUI app: already Running"
  elif [ "$ST_STATE" = NeedsLogin ]; then
    CHANGED=1
    src="$GUI_PREFS_FILE"
    if [ -z "$recorded" ]; then   # it went NeedsLogin after the proof: rebuild from the app's current prefs
      src="$TMP/gui-prefs-now.txt"
      # shellcheck disable=SC2086  # GUI_PREF_KEYS is a word list
      prefs_values app $GUI_PREF_KEYS > "$src" || fail "rollback" "the app's node needs a login and its prefs cannot be read: log in from the app's menu"
    fi
    while IFS= read -r f; do flags+=("$f"); done <<EOF
$(recorded_up_flags "$src")
EOF
    if grep -q '^ExitNodeID=.' "$src"; then
      say "WARNING: the exit node ($(sed -n 's/^ExitNodeID=//p' "$src")) cannot be set from its ID: choose it again in the app."
    fi
    say "GUI app: its node needs a login (deleted in the admin console?); restoring the recorded prefs"
    bring_up app --reset ${flags[@]+"${flags[@]}"}
  else
    CHANGED=1
    bring_up app        # bare: sets WantRunning only, keeps every other pref
  fi
  converge_serve app

  # 4. Verify.
  local bad=0 rec=()
  if read_status app && [ "$ST_STATE" = Running ] && [ -n "$ST_IP4" ]; then :; else say "verify: GUI backend ${ST_STATE:-not answering}, IPv4 ${ST_IP4:-none}"; bad=1; fi
  check_prefs app WantRunning=true || { say "verify: prefs:$PREF_DIFF"; bad=1; }
  if [ -n "$recorded" ]; then
    # The exit node is only warned about: a node that had to log in again
    # cannot get it back from its recorded ID, so it would never verify.
    while IFS= read -r f; do
      case "$f" in ""|ExitNodeID=*) continue ;; esac
      rec+=("$f")
    done < "$GUI_PREFS_FILE"
    if [ "${#rec[@]}" -gt 0 ]; then
      check_prefs app "${rec[@]}" || { say "verify: GUI prefs differ from the record:$PREF_DIFF"; bad=1; }
    fi
    want_exit="$(sed -n 's/^ExitNodeID=//p' "$GUI_PREFS_FILE")"
    have_exit="$(prefs_values app ExitNodeID 2>/dev/null | sed -n 's/^ExitNodeID=//p')"
    [ "$want_exit" = "$have_exit" ] || say "WARNING: the exit node is '${have_exit:-none}', the record says '$want_exit': set it again in the app (not part of the verification)"
  fi
  serve_matches app || { say "verify: serve/funnel differs"; bad=1; }
  ! daemon_loaded || { say "verify: the daemon is still loaded"; bad=1; }
  [ "$(start_on_login)" = 1 ] || { say "verify: start on login is off"; bad=1; }
  if [ -n "$HELPER_LABEL" ] && [ "$(helper_state)" = disabled ]; then say "verify: the login-item helper is still disabled"; bad=1; fi
  [ "$bad" = 0 ] || fail "verify" "see the lines above"
  read_status app || true
  say "verified: back on the GUI app, node $ST_DNS $ST_IP4; prefs as recorded${recorded:+ in $GUI_PREFS_FILE}; serve/funnel as configured; daemon gone; start on login and the login-item helper on"
}

# ── main ───────────────────────────────────────────────────────
resolve_brew
resolve_helper

if [ "$DETACH" = 1 ] && [ "${TS_CUTOVER_DETACHED:-0}" != 1 ]; then
  ensure_log_dir
  holder="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then say "ERROR: another run (pid $holder) is going; see $LOG_DIR/last-run.log"; exit 1; fi
  TS_CUTOVER_DETACHED=1 nohup "${BASH:-/bin/bash}" "$SCRIPT_ABS" "${ORIG_ARGS[@]}" > "$LOG_DIR/detached.out" 2>&1 < /dev/null &
  chown "$GUI_USER" "$LOG_DIR/detached.out" 2>/dev/null || true
  say "running in the background as pid $!; safe to disconnect"
  say "follow: tail -F $LOG_DIR/last-run.log   (done at '$NAME: finished: exit <code>')"
  exit 0
fi

case "$MODE" in
  preflight) begin_run preflight.log; run_preflight ;;
  cutover)   begin_run last-run.log; run_cutover ;;
  rollback)  begin_run last-run.log; run_rollback ;;
esac
