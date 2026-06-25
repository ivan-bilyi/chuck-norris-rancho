#!/bin/bash
# Set/refresh Chuck's Claude Code OAuth token (durable, env-based auth).
#
# Why: Relay spawns `claude` and spreads its own process.env into the child.
# Relay loads ~/relay/.env via dotenv at startup, so a CLAUDE_CODE_OAUTH_TOKEN
# there authenticates every spawned session — independent of the macOS keychain
# (whose interactive-login token expires and logs Chuck out).
#
# Usage:
#   1) claude setup-token          # interactive, opens browser -> prints sk-ant-oat01-...
#   2) set-claude-token.sh <token> # writes .env, restarts Relay, verifies
set -uo pipefail

ENV_FILE="$HOME/relay/.env"
KEY="CLAUDE_CODE_OAUTH_TOKEN"

token="${1:-}"
if [ -z "$token" ]; then
  echo "Usage: $0 <oauth-token>" >&2
  echo "Get one via: claude setup-token" >&2
  exit 2
fi
case "$token" in
  sk-ant-oat01-*) : ;;
  *) echo "WARN: token doesn't look like 'sk-ant-oat01-...' — proceeding anyway." >&2 ;;
esac

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE not found" >&2
  exit 1
fi

# Backup, then upsert the key (drop any existing line, append fresh).
cp "$ENV_FILE" "$ENV_FILE.bak.$(date +%Y%m%d%H%M%S)"
grep -v "^${KEY}=" "$ENV_FILE" > "$ENV_FILE.tmp" || true
printf '%s=%s\n' "$KEY" "$token" >> "$ENV_FILE.tmp"
mv "$ENV_FILE.tmp" "$ENV_FILE"
chmod 600 "$ENV_FILE"
echo "Wrote ${KEY} to $ENV_FILE (backup kept)."

# Restart Relay so dotenv reloads the new token into its process.env.
echo "Restarting Relay..."
launchctl kickstart -k "gui/$(id -u)/com.rancho.relay"
sleep 3

# Verify the token authenticates a fresh claude run.
eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null)"
export CLAUDE_CODE_OAUTH_TOKEN="$token"
echo "Verifying auth..."
res="$(claude -p "reply with just: OK" --output-format json 2>&1)"
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
