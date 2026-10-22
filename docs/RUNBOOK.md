# Rancho Runbook

## Architecture

Rancho (chuck-norris-rancho) — infrastructure repository for deploying **Relay**, a Discord-to-Claude-Code transport layer.

```
Windows (this repo)              Mac Mini M1 (Tailscale VPN)
├── relay/                       ├── ~/relay/              (Relay bot)
├── infra/                       ├── ~/shared/             (Syncthing sync)
├── scripts/                     ├── ~/projects/           (dev projects)
└── docs/                        └── launchd: com.rancho.relay
```

Components on Mac Mini:
- **Relay** — Node.js Discord bot, spawns `claude -p` CLI sessions
- **Claude Code CLI** — AI agent, authorized via OAuth subscription
- **Syncthing** — file sync between Mac and Windows
- **Tailscale** — VPN for remote access
- **launchd** — auto-start service

## Connection

### Mac Mini (Tailscale VPN)

```bash
ssh rancho
```

SSH config (`~/.ssh/config`):
```
Host rancho
    HostName <TAILSCALE_IP>
    User i.beliy
    ServerAliveInterval 60
    ServerAliveCountMax 3
```

Setup: `bash scripts/setup-ssh.sh mac <TAILSCALE_IP>`

## Deployment

### Prerequisites (physically on Mac, ~12 min)

1. System Settings -> General -> Sharing -> **Remote Login** -> ON
2. System Settings -> Users & Groups -> **Automatic Login** -> select user
3. System Settings -> Energy Saver -> **Prevent sleep**, **Wake for network**, **Auto restart after power failure**
4. Install Homebrew: `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`
5. Install Tailscale: `brew install --cask tailscale` -> log in -> `tailscale up --ssh`

### Automated Setup (via SSH)

```bash
scp infra/setup-mac.sh rancho:/tmp/
ssh rancho "sed -i '' 's/\r$//' /tmp/setup-mac.sh && bash /tmp/setup-mac.sh"
```

The script automatically:
- Configures energy settings
- Installs Node.js 22, Syncthing, Claude Code CLI
- Creates directories (~/relay, ~/shared, ~/projects)
- Sets up launchd service for Relay

### After setup-mac.sh

1. `ssh rancho "claude setup-token"` -> open URL in browser -> authorize -> paste code
2. Fill in Discord bot token: `ssh rancho "nano ~/relay/.env"`
3. Clone this repo to `~/chuck-norris-rancho` on the Mac and deploy Relay from it: see [Relay deploy](#relay-deploy). The deploy loads the launchd service if it is not loaded yet.
4. Pair Syncthing: `ssh -L 8384:localhost:8384 rancho` -> http://localhost:8384
5. Test: `bash scripts/status.sh` -> send message in Discord
6. Reboot test: `ssh rancho "sudo shutdown -r now"` -> wait 3 min -> `bash scripts/status.sh`

## Discord Bot Setup

1. [Discord Developer Portal](https://discord.com/developers/applications) -> New Application
2. **Bot** tab:
   - Reset Token -> save as `DISCORD_BOT_TOKEN`
   - Privileged Gateway Intents:
     - **Message Content Intent** — required!
     - **Server Members Intent**
3. **OAuth2** -> URL Generator:
   - Scopes: `bot`, `applications.commands`
   - Bot Permissions: `Send Messages`, `Read Message History`, `View Channels`, `Add Reactions`
   - Open URL -> add to server
4. Register projects: use `/project add` slash command in Discord

## Daily Operations

### Check status
```bash
bash scripts/status.sh
```

### View logs
```bash
bash scripts/logs.sh        # main logs
bash scripts/logs.sh error   # error logs only
```

### Restart Relay
```bash
bash scripts/restart.sh
```

### Deploy update
See [Relay deploy](#relay-deploy).

### Register a new project
In Discord: `/project add <name> <path> <channel>`

Example: `/project add zbroya /Users/i.beliy/projects/zbroya.science #zbroya-science`

## Troubleshooting

### Relay not responding

1. Check service: `bash scripts/status.sh`
2. Check logs: `bash scripts/logs.sh error`
3. Restart: `bash scripts/restart.sh`

### Claude CLI errors

1. OAuth token expired: `ssh rancho "claude setup-token"`
2. After re-auth, restart Relay: `bash scripts/restart.sh`

### Session stuck in "running" state

Relay automatically resets stuck sessions on startup. To force:
```bash
bash scripts/restart.sh
```

Or manually: `ssh rancho "sqlite3 ~/relay/relay.db \"UPDATE sessions SET status='idle' WHERE status='running'\""`

### Bot connected but no messages received

**Message Content Intent** not enabled on Discord Developer Portal.
Bot tab -> Privileged Gateway Intents -> Message Content Intent -> Save.

### Mac Mini not reachable

1. Check Tailscale: `tailscale status` (from Windows)
2. Ping: `tailscale ping <mac-ip>`
3. If Mac not visible — physically check it's powered on and connected to network

### Mac Mini: Relay not starting after reboot

1. `ssh rancho "launchctl print gui/\$(id -u)/com.rancho.relay"`
2. Logs: `ssh rancho "tail -20 ~/relay/logs/relay.error.log"`
3. Manual start: `ssh rancho "cd ~/relay && node dist/index.js"`

## Maintenance

### Update Relay
See [Relay deploy](#relay-deploy).

### Update Claude Code CLI
```bash
ssh rancho "npm install -g @anthropic-ai/claude-code"
bash scripts/restart.sh
```

### Backup database
```bash
ssh rancho "cp ~/relay/relay.db ~/relay/relay.db.bak"
```

## Relay deploy

Relay is deployed **on the Mac**, from the repo clone `~/chuck-norris-rancho`, by
`scripts/relay-deploy.sh`. It builds a git revision outside the live tree and swaps in only
the code, so `~/relay` always runs a known commit. There is no laptop-side deploy: copying a
working tree to the host ships uncommitted or unmerged code and leaves no record of what runs.

```bash
# plan only: current state, target SHA, what moves and what stays (changes nothing)
ssh rancho 'cd ~/chuck-norris-rancho && git pull --ff-only && scripts/relay-deploy.sh --dry-run'

# deploy origin/main (or: --sha <rev>)
ssh rancho 'cd ~/chuck-norris-rancho && git pull --ff-only && scripts/relay-deploy.sh'

# what is deployed
ssh rancho 'cat ~/relay/REVISION'

# roll back to the previous code (run it again to return)
ssh rancho '~/chuck-norris-rancho/scripts/relay-deploy.sh --rollback'
```

What the script does:

1. `git fetch` in the clone (refs only; the clone's work tree is not touched), then
   `git archive <sha> relay/` into a fresh build dir under `~/.cache/relay-deploy/`.
2. `npm ci` and `npm run build` there with the node binary named in the launchd plist, then it
   loads every dependency under that node. Native modules must match the node that runs Relay.
3. It waits until Relay has no `claude` child process (no turn in flight; `--no-wait` skips this).
4. It moves the live **code** items (`dist node_modules package.json package-lock.json REVISION
   src tsconfig.json CLAUDE.md relay.env.example templates`) to `~/relay.prev` and moves the
   new build in. These are renames on one volume.
5. `launchctl kickstart -k gui/<uid>/com.rancho.relay`, or `launchctl bootstrap` with the plist when the service is not loaded. Then a smoke test:
   - a new pid is running;
   - the log shows `Relay online as` (Discord ready) and `Reconcile scheduler started`;
   - `GET 127.0.0.1:<RELAY_NOTIFY_PORT>/healthz` answers 200;
   - the pid stays up for 10 s;
   - a one-line `claude -p` auth probe on Haiku runs with Relay's own token.
6. If a service check fails, it swaps the previous code back and restarts again (exit 4).
   `~/relay.prev` then holds the failed build, marked so that `--rollback` refuses it.
   A failed auth probe does not roll back, because rolling back would not fix auth. The run
   exits 3: refresh the token with `infra/set-claude-token.sh`.

Never touched: `.env*`, `relay.db*`, `logs/` and anything else in `~/relay` that is not a code
item. The script reads only the log and two `.env` settings: `RELAY_NOTIFY_PORT`, and
`CLAUDE_CODE_OAUTH_TOKEN`, which is passed to the auth probe through its environment and never printed.

`~/relay/REVISION` is the deploy record. Its format is `key=value` lines: `sha`, `ref`,
`subject`, `deployed_at` (UTC), `node`. It moves with the code, so after a rollback it names
what actually runs. A missing file means the live code was not deployed by this script. Each
run appends one line to `~/.cache/relay-deploy/history.log`.

Exit codes:

| Code | Meaning |
|---|---|
| 0 | deployed |
| 1 | failed before anything live changed |
| 2 | usage error |
| 3 | deployed, but the auth probe failed |
| 4 | smoke test failed and the previous code is live again |
| 5 | smoke test failed and the revert did not come up either: check the service by hand |

Paths and the label come from the launchd plist and `$HOME`. They can be overridden with
`RELAY_*` variables (see the script header). Other flags: `--build-only`, `--no-fetch`,
`--no-auth-probe`.

## Vitrina (self-hosted artifacts)

Sibling service, launchd `com.rancho.vitrina`, public on `127.0.0.1:4477` (Tailscale Funnel
`https://whitemini.impala-symmetric.ts.net`, tailnet-only `:8444`), admin API on `127.0.0.1:4478`.
Full design and CLI: [ARTIFACTS.md](ARTIFACTS.md).

```bash
# deploy after a change (runs on the Mac, from the repo clone)
ssh rancho 'cd ~/chuck-norris-rancho && git pull && scripts/vitrina-deploy.sh'

# health, logs, service
ssh rancho 'curl -s localhost:4477/healthz; curl -s localhost:4478/healthz'
ssh rancho 'tail -30 ~/vitrina/logs/vitrina.log ~/vitrina/logs/vitrina.err.log'
ssh rancho 'launchctl kickstart -k gui/$(id -u)/com.rancho.vitrina'

# what is published, by whom, for whom
ssh rancho 'vitrina list'
ssh rancho 'vitrina revoke <slug>'

# funnel / tailnet mounts
ssh rancho '/Applications/Tailscale.app/Contents/MacOS/Tailscale serve status'
```

Config: `~/.config/rancho/vitrina.env` (token, ports, base URLs), `~/.config/rancho/vitrina.json`
(people + audiences + portal tokens). Data: `~/vitrina/data/` (back up with the Relay db).

## SSH Tunnel Cheat Sheet

```bash
# Syncthing GUI
ssh -L 8384:localhost:8384 rancho
```
