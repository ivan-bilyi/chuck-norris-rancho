#!/bin/bash
# Set/refresh Chuck's Claude Code OAuth token (durable, env-based auth).
#
# Why: Relay spawns `claude` and spreads its own process.env into the child.
# Relay loads ~/relay/.env via dotenv at startup, so a CLAUDE_CODE_OAUTH_TOKEN
# there authenticates every spawned session — independent of the macOS keychain
# (whose interactive-login token expires and logs Chuck out).
#
# The token never goes on a command line (it would land in shell history and
# in `ps`): it is read from a hidden prompt, or from stdin when stdin is not a
# terminal, and it is never printed. Arguments are refused.
#
# Usage (installed on the Mac as ~/bin/set-claude-token.sh):
#   1) claude setup-token                      # opens a browser, prints sk-ant-oat01-...
#   2) set-claude-token.sh                     # paste the token at the hidden prompt
#      or pipe it in, e.g. from a laptop:  pbpaste | ssh rancho '~/bin/set-claude-token.sh'
#
# It backs up ~/relay/.env (0600), replaces the token line atomically (0600),
# restarts Relay (launchctl kickstart -k: a turn in flight is cut off) and
# verifies the token with one claude call (timeout RELAY_TOKEN_VERIFY_TIMEOUT,
# default 120 s). If it is interrupted, the temp file holding the token is
# removed.
set -uo pipefail
umask 077

ENV_FILE="${RELAY_ENV_FILE:-$HOME/relay/.env}"
VERIFY_TIMEOUT="${RELAY_TOKEN_VERIFY_TIMEOUT:-120}"
KEY="CLAUDE_CODE_OAUTH_TOKEN"
LABEL="${RELAY_LABEL:-com.rancho.relay}"
PLIST="${RELAY_PLIST:-$HOME/Library/LaunchAgents/$LABEL.plist}"

case "${1:-}" in
  "") ;;
  -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  *)
    echo "ERROR: this script takes no arguments: a token on the command line lands in shell history and in ps." >&2
    echo "Run it without arguments and paste the token at the hidden prompt, or pipe the token on stdin." >&2
    echo "If you just passed a token, it is in your shell history now: delete that entry, or rotate the token." >&2
    exit 2 ;;
esac

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE not found" >&2
  exit 1
fi

# Read the token: hidden prompt on a terminal, else the first line of stdin.
token=""
if [ -t 0 ]; then
  printf 'Paste the OAuth token (input hidden), then press Enter: ' >&2
  IFS= read -rs token || true
  printf '\n' >&2
else
  IFS= read -r token || true
fi
token="${token//[$' \t\r\n']/}"
if [ -z "$token" ]; then
  echo "ERROR: no token read" >&2
  exit 2
fi
case "$token" in
  sk-ant-oat01-*) : ;;
  *) echo "WARN: token doesn't look like 'sk-ant-oat01-...' — proceeding anyway." >&2 ;;
esac

# The temp file below holds the token until it is renamed over .env: remove
# it on any exit or interruption before that.
# On an interruption, say what state it left.
tmp=""; stage=writing
on_exit() {
  local rc=$? renamed=0
  if [ -n "$tmp" ]; then
    if [ -e "$tmp" ]; then rm -f "$tmp"; else renamed=1; fi   # gone = already renamed over .env
  fi
  if [ "$rc" -ge 128 ]; then
    if [ "$stage" = writing ] && [ "$renamed" = 1 ]; then stage=written; fi
    case "$stage" in
      writing) echo "Interrupted: $ENV_FILE is unchanged." >&2 ;;
      written) echo "Interrupted after $ENV_FILE got the new token but before Relay restarted: run launchctl kickstart -k gui/$(id -u)/$LABEL, or re-run this script." >&2 ;;
      *)       echo "Interrupted during verification: the token is written and Relay restarted." >&2 ;;
    esac
  fi
}
trap on_exit EXIT
trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM

# Backup (0600), then replace the key in a 0600 temp file and rename it over
# .env, so .env is never partly written or readable by others.
backup="$ENV_FILE.bak.$(date +%Y%m%d%H%M%S)"
cp "$ENV_FILE" "$backup" && chmod 600 "$backup" || { echo "ERROR: cannot back up $ENV_FILE" >&2; exit 1; }
chmod 600 "$ENV_FILE".bak.* 2>/dev/null || true     # older backups were made world-readable
tmp="$(mktemp "$ENV_FILE.tmp.XXXXXX")" || { echo "ERROR: cannot create a temp file next to $ENV_FILE" >&2; exit 1; }
{ grep -v "^${KEY}=" "$ENV_FILE" || true; printf '%s=%s\n' "$KEY" "$token"; } > "$tmp" \
  && chmod 600 "$tmp" && mv "$tmp" "$ENV_FILE" \
  || { echo "ERROR: could not write $ENV_FILE (unchanged; backup at $backup)" >&2; exit 1; }
tmp=""; stage=written
echo "Wrote ${KEY} to $ENV_FILE (backup: $backup)."

# Restart Relay so dotenv reloads the new token into its process.env.
echo "Restarting Relay..."
launchctl kickstart -k "gui/$(id -u)/$LABEL"
stage=restarted
sleep 3

# Run "$@" with a time limit (macOS has no `timeout`); 143/137 when killed.
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

# Verify the token authenticates a fresh claude run, with the PATH the Relay
# service uses (non-interactive SSH has no Homebrew PATH), no MCP servers and
# no saved session.
svc_path="$(plutil -extract EnvironmentVariables.PATH raw -o - "$PLIST" 2>/dev/null || true)"
export PATH="${svc_path:+$svc_path:}$PATH"
export CLAUDE_CODE_OAUTH_TOKEN="$token"
echo "Verifying auth..."
rc=0
res="$(with_timeout "$VERIFY_TIMEOUT" claude -p "reply with just: OK" --output-format json \
  --no-session-persistence --strict-mcp-config 2>&1)" || rc=$?
if printf '%s' "$res" | grep -q '"is_error":false'; then
  echo "✅ Auth OK — Chuck is logged in (token accepted)."
elif [ "$rc" -ge 128 ]; then
  echo "❌ No answer from claude within ${VERIFY_TIMEOUT}s (network?). The token is written and Relay restarted; verify later." >&2
  exit 1
elif printf '%s' "$res" | grep -qi "not logged in"; then
  echo "❌ Still 'Not logged in' — token invalid/expired. Re-run 'claude setup-token'." >&2
  exit 1
else
  echo "⚠️ Unexpected probe result:" >&2
  printf '%s\n' "$res" | head -c 400 >&2
  echo >&2
  exit 1
fi
