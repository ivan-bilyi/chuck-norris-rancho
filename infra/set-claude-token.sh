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
# verifies the token with one claude call.
set -uo pipefail
umask 077

ENV_FILE="${RELAY_ENV_FILE:-$HOME/relay/.env}"
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

# Backup (0600), then replace the key in a 0600 temp file and rename it over
# .env, so .env is never partly written or readable by others.
backup="$ENV_FILE.bak.$(date +%Y%m%d%H%M%S)"
cp "$ENV_FILE" "$backup" && chmod 600 "$backup" || { echo "ERROR: cannot back up $ENV_FILE" >&2; exit 1; }
chmod 600 "$ENV_FILE".bak.* 2>/dev/null || true     # older backups were made world-readable
tmp="$(mktemp "$ENV_FILE.tmp.XXXXXX")" || { echo "ERROR: cannot create a temp file next to $ENV_FILE" >&2; exit 1; }
{ grep -v "^${KEY}=" "$ENV_FILE" || true; printf '%s=%s\n' "$KEY" "$token"; } > "$tmp" \
  && chmod 600 "$tmp" && mv "$tmp" "$ENV_FILE" \
  || { rm -f "$tmp"; echo "ERROR: could not write $ENV_FILE (unchanged; backup at $backup)" >&2; exit 1; }
echo "Wrote ${KEY} to $ENV_FILE (backup: $backup)."

# Restart Relay so dotenv reloads the new token into its process.env.
echo "Restarting Relay..."
launchctl kickstart -k "gui/$(id -u)/$LABEL"
sleep 3

# Verify the token authenticates a fresh claude run, with the PATH the Relay
# service uses (non-interactive SSH has no Homebrew PATH).
svc_path="$(plutil -extract EnvironmentVariables.PATH raw -o - "$PLIST" 2>/dev/null || true)"
export PATH="${svc_path:+$svc_path:}$PATH"
export CLAUDE_CODE_OAUTH_TOKEN="$token"
echo "Verifying auth..."
res="$(claude -p "reply with just: OK" --output-format json --no-session-persistence 2>&1)"
if printf '%s' "$res" | grep -q '"is_error":false'; then
  echo "✅ Auth OK — Chuck is logged in (token accepted)."
elif printf '%s' "$res" | grep -qi "not logged in"; then
  echo "❌ Still 'Not logged in' — token invalid/expired. Re-run 'claude setup-token'." >&2
  exit 1
else
  echo "⚠️ Unexpected probe result:" >&2
  printf '%s\n' "$res" | head -c 400 >&2
  echo >&2
  exit 1
fi
