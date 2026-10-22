#!/bin/bash
# Setup Mac Mini for Relay (Discord-to-Claude-Code transport)
# Prerequisites: Homebrew, Tailscale, SSH — already configured (Phase A)
# Run via SSH: scp infra/setup-mac.sh rancho:/tmp/ && ssh rancho 'bash /tmp/setup-mac.sh'
set -euo pipefail

MAC_USER="i.beliy"
MAC_HOME="/Users/$MAC_USER"

echo "=== [1/7] Energy Settings ==="
sudo pmset -a sleep 0 displaysleep 0 disksleep 0
sudo pmset -a autorestart 1
sudo pmset -a womp 1
echo "OK: $(pmset -g | grep -E 'sleep|autorestart|womp' | head -5)"

echo ""
echo "=== [2/7] Installing packages via Homebrew ==="
brew install node@22 git syncthing jq sqlite tmux 2>/dev/null || true

# Ensure node@22 is in PATH
if ! command -v node &>/dev/null; then
  echo 'export PATH="/opt/homebrew/opt/node@22/bin:$PATH"' >> "$MAC_HOME/.zprofile"
  export PATH="/opt/homebrew/opt/node@22/bin:$PATH"
fi

echo "Node.js: $(node --version)"
echo "npm: $(npm --version)"

echo ""
echo "=== [3/7] Installing Claude Code CLI ==="
npm install -g @anthropic-ai/claude-code 2>/dev/null || true
echo "Claude Code: $(claude --version 2>/dev/null || echo 'installed, needs setup-token')"

echo ""
echo "=== [4/7] Creating directories ==="
mkdir -p "$MAC_HOME/relay/logs"
mkdir -p "$MAC_HOME/shared/inbox"
mkdir -p "$MAC_HOME/shared/outbox"
mkdir -p "$MAC_HOME/projects"
echo "OK"

echo ""
echo "=== [5/7] Deploying Relay ==="
RELAY_SRC="$MAC_HOME/relay"

if [ -f "$RELAY_SRC/package.json" ]; then
  echo "Relay source found, building..."
  cd "$RELAY_SRC"
  npm install
  npm run build
  echo "Relay built successfully"
else
  echo "WARNING: Relay source not found at $RELAY_SRC"
  echo "Deploy with: scripts/relay-deploy.sh (on this Mac, from the repo clone)"
fi

# Create .env from template if not exists
if [ ! -f "$RELAY_SRC/.env" ]; then
  if [ -f "$RELAY_SRC/relay.env.example" ]; then
    cp "$RELAY_SRC/relay.env.example" "$RELAY_SRC/.env"
    echo "Created .env from template — fill in DISCORD_BOT_TOKEN"
  fi
fi

echo ""
echo "=== [6/7] Setting up Syncthing ==="
brew services start syncthing 2>/dev/null || true

if [ ! -f "$MAC_HOME/.config/syncthing/config.xml" ]; then
  syncthing generate --config="$MAC_HOME/.config/syncthing"
fi

cat > "$MAC_HOME/shared/.stignore" << 'STIGNORE'
node_modules
.git
__pycache__
*.pyc
dist
build
.next
.cache
.venv
venv
STIGNORE

echo ""
echo "=== [7/7] Setting up launchd service ==="
LAUNCH_AGENTS="$MAC_HOME/Library/LaunchAgents"
mkdir -p "$LAUNCH_AGENTS"

# Unload old NanoClaw services if present
launchctl bootout "gui/$(id -u)/com.whiteclaw.nanoclaw" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.whiteclaw.colima" 2>/dev/null || true

# Install Relay LaunchAgent
cat > "$LAUNCH_AGENTS/com.rancho.relay.plist" << 'PLIST_RELAY'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.rancho.relay</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/opt/node@22/bin/node</string>
        <string>__MAC_HOME__/relay/dist/index.js</string>
    </array>
    <key>WorkingDirectory</key>
    <string>__MAC_HOME__/relay</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>__MAC_HOME__</string>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/opt/homebrew/opt/node@22/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>StandardOutPath</key>
    <string>__MAC_HOME__/relay/logs/relay.log</string>
    <key>StandardErrorPath</key>
    <string>__MAC_HOME__/relay/logs/relay.error.log</string>
</dict>
</plist>
PLIST_RELAY
sed -i '' "s|__MAC_HOME__|$MAC_HOME|g" "$LAUNCH_AGENTS/com.rancho.relay.plist"

# Load Relay service (only if built)
if [ -f "$RELAY_SRC/dist/index.js" ] && [ -f "$RELAY_SRC/.env" ]; then
  launchctl bootout "gui/$(id -u)/com.rancho.relay" 2>/dev/null || true
  sleep 1
  launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENTS/com.rancho.relay.plist"
  echo "Relay LaunchAgent loaded"
else
  echo "WARNING: Relay not started — missing dist/index.js or .env"
  echo "Deploy with: scripts/relay-deploy.sh (on this Mac, from the repo clone)"
fi

echo ""
echo "=========================================="
echo "  Mac Mini ready!"
echo "=========================================="
echo ""
echo "Services:"
echo "  Relay:     launchctl print gui/$(id -u)/com.rancho.relay"
echo "  Syncthing: brew services info syncthing"
echo ""
echo "Logs:"
echo "  tail -f $MAC_HOME/relay/logs/relay.log"
echo "  tail -f $MAC_HOME/relay/logs/relay.error.log"
echo ""
echo "Syncthing GUI (via SSH tunnel):"
echo "  ssh -L 8384:localhost:8384 rancho"
echo "  http://localhost:8384"
echo ""
echo "Next steps:"
echo "1. claude setup-token  (if not already authorized)"
echo "2. Fill DISCORD_BOT_TOKEN in ~/relay/.env"
echo "3. Clone the repo to ~/chuck-norris-rancho, then run scripts/relay-deploy.sh there"
echo "4. bash scripts/restart.sh  (from Windows, to start the service)"
echo "5. Pair Syncthing with Windows"
echo "6. Test: send message in Discord"
