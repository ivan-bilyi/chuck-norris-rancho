#!/bin/bash
# Daily Claude Code auto-update for Chuck (Mac Mini).
# Installed on the Mac as ~/bin/claude-autoupdate.sh, driven by the
# com.rancho.claude-update LaunchAgent (daily, 04:00 Mac local time).
#
# Behaviour:
#   - runs `claude update` (default/stable channel)
#   - logs before/after version to ~/relay/logs/claude-update.log
#   - notifies the #homelab Discord channel via Relay's local notify
#     server ONLY on a version change or a failure (silent when already
#     up to date, to avoid daily spam)
set -uo pipefail

eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null)"
export PATH="/opt/homebrew/bin:/opt/homebrew/opt/node@22/bin:${PATH:-/usr/bin:/bin}"

LOG="$HOME/relay/logs/claude-update.log"
NOTIFY_URL="http://127.0.0.1:${RELAY_NOTIFY_PORT:-4466}/notify"
NOTIFY_PROJECT="homelab"

ts()  { date "+%Y-%m-%dT%H:%M:%S%z"; }
log() { echo "[$(ts)] $*" >> "$LOG"; }

# Pure-bash JSON string escaper (no python/jq dependency).
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/}"
  s="${s//$'\t'/ }"
  printf '"%s"' "$s"
}

# Best-effort Discord notify; never fails the script if Relay is down.
notify() {
  local level="$1" content="$2" body
  body="$(printf '{"project":"%s","content":%s,"level":"%s"}' \
    "$NOTIFY_PROJECT" "$(json_escape "$content")" "$level")"
  curl -fsS --max-time 10 -X POST "$NOTIFY_URL" \
    -H "Content-Type: application/json" --data "$body" >/dev/null 2>&1 \
    || log "notify failed (relay down?): $content"
}

mkdir -p "$(dirname "$LOG")"

if ! command -v claude >/dev/null 2>&1; then
  log "ERROR: claude not found in PATH"
  notify error "⚠️ claude-update: бінарник claude не знайдено в PATH на Mac Mini."
  exit 1
fi

before="$(claude --version 2>/dev/null | awk '{print $1}')"
log "checking for updates (current: ${before:-unknown})"

out="$(claude update 2>&1)"; rc=$?
log "claude update rc=$rc :: ${out//$'\n'/ | }"

after="$(claude --version 2>/dev/null | awk '{print $1}')"

if [ "$rc" -ne 0 ]; then
  log "ERROR: claude update failed (rc=$rc)"
  notify error "⚠️ claude-update на Mac Mini впав (rc=$rc). Версія: ${after:-unknown}. ${out:0:400}"
  exit "$rc"
fi

if [ "$before" != "$after" ]; then
  log "updated: $before -> $after"
  notify info "✅ Claude Code оновлено на Mac Mini: ${before} → ${after}"
else
  log "already up to date ($after)"
fi
exit 0
