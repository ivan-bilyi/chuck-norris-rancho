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

OAuth token expired or rotated:

1. Get a new token: `ssh -t rancho 'claude setup-token'` (prints `sk-ant-oat01-...`).
2. Install it with `~/bin/set-claude-token.sh`, a copy of `infra/set-claude-token.sh`. It
   restarts Relay and verifies the token. The token never goes on a command line, which would
   put it in shell history and `ps`:
   - interactive: `ssh -t rancho '~/bin/set-claude-token.sh'`, then paste at the hidden prompt;
   - from the laptop clipboard: `pbpaste | ssh rancho '~/bin/set-claude-token.sh'`.

   The script refuses arguments. It writes `~/relay/.env` atomically with mode 0600, keeps a
   0600 backup `.env.bak.<timestamp>`, and tightens older backups to 0600.

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
# plan only: current state, leftovers, target SHA, what moves and what stays (changes nothing)
ssh rancho 'cd ~/chuck-norris-rancho && git pull --ff-only && scripts/relay-deploy.sh --dry-run'

# deploy origin/main (or: --sha <rev>) in the background; safe to disconnect
ssh rancho 'cd ~/chuck-norris-rancho && git pull --ff-only && scripts/relay-deploy.sh --detach'
ssh rancho 'tail -n 20 ~/.cache/relay-deploy/last-run.log'   # repeat until "relay-deploy: finished: exit <code>"

# what is deployed
ssh rancho 'cat ~/relay/REVISION'

# roll back to the previous code (run it again to return); --detach works here too
ssh rancho '~/chuck-norris-rancho/scripts/relay-deploy.sh --rollback --detach'
```

`--detach` restarts the script under `nohup` with its output in
`~/.cache/relay-deploy/last-run.log` and returns at once. A foreground run is also safe: from
the swap to the end of the smoke test (and any revert) the script ignores HUP, INT and TERM
and keeps going if its output is gone, so Ctrl-C or a dropped SSH session cannot leave a
half-done deploy. Before the swap, an interrupted run changes nothing live. To watch a
foreground run without tying it to the SSH session, `screen` is available on the host;
`tmux` is not installed.

What the script does:

1. It checks for leftovers of an interrupted earlier run before changing anything:
   - **Deleted:** staging that never went live (`~/relay.next.partial`, or a `~/relay.next`
     whose status is `staged`). Also deleted: an older rollback target `~/relay.prev.old` when
     the newer `~/relay.prev` exists, which stays the rollback target.
   - **Renamed back:** `~/relay.prev.old` becomes `~/relay.prev` when neither `~/relay.prev`
     nor `~/relay.next` exists.
   - **Refused,** with the commands to resolve it: `~/relay.swap`, a `~/relay.prev` it did not
     make, or a `~/relay.next` holding code that was live. These are cases where a leftover may
     be the only copy of code that ran.
2. `git fetch` in the clone (refs only; the clone's work tree is not touched). If the target
   commit is already live with status `ok`, the run says "already live", changes nothing (no
   restart, `~/relay.prev` kept), runs the auth probe and exits 0, or 3 if the probe fails.
   `--force` rebuilds and restarts it anyway. Otherwise it runs `git archive <sha> relay/`
   into a fresh build dir under `~/.cache/relay-deploy/`.
3. `npm ci` and `npm run build` there with the node binary named in the launchd plist, then it
   loads every dependency under that node. Native modules must match the node that runs Relay.
4. It stages the build in `~/relay.next`. The build is assembled in `~/relay.next.partial` and
   renamed when complete. Then it waits until Relay has no `claude` child process (no turn in
   flight; up to 15 minutes; `--no-wait` skips this).
5. From here signals are ignored. It re-checks that no turn started meanwhile (if one did, it
   waits again). Then it swaps the live **code** items (`dist node_modules package.json
   package-lock.json REVISION src tsconfig.json CLAUDE.md relay.env.example templates`) with
   the staged ones by renames on one volume. What happens to the code that was live:
   - **Proven** (status `ok`, or code from before this script): it becomes `~/relay.prev`, the
     rollback target.
   - **Same commit** (`--force`): it is still the revert target if the restart fails. On
     success the existing `~/relay.prev` is kept, because a copy of the live commit is no use
     as a rollback target.
   - **Never passed a smoke test** (an earlier run was killed): it is dropped, and the existing
     `~/relay.prev` stays the rollback target and the revert target.
6. `launchctl kickstart -k gui/<uid>/com.rancho.relay`, or `launchctl bootstrap` with the
   plist when the service is not loaded. Then a smoke test:
   - a new pid is running;
   - the log shows `Relay online as` (Discord ready) and `Reconcile scheduler started`;
   - `GET 127.0.0.1:<RELAY_NOTIFY_PORT>/healthz` answers 200;
   - the pid stays up for 10 s.

   A fatal start error in the error log (`Failed to start bot`, a missing bot token) or the
   process going away fails the test at once instead of waiting for the 90 s timeout.
7. If the smoke test fails, it swaps the revert target back, restarts and smoke-tests again.
   It drops the new build and puts the old `~/relay.prev` back, so after exit 4 everything is
   as it was. The one exception is a run that started from unproven live code: there the
   proven `~/relay.prev` is what goes live, and the message says so.
8. A one-line `claude -p` auth probe on Haiku runs with Relay's own token, with a 120 s timeout.
   A failed probe does not roll back, because rolling back would not change auth or the
   network. The run exits 3: refresh the token (see Claude CLI errors) or check the network.

Never touched: `.env*`, `relay.db*`, `logs/` and anything else in `~/relay` that is not a code
item. The script reads only the logs and two `.env` settings: `RELAY_NOTIFY_PORT`, and
`CLAUDE_CODE_OAUTH_TOKEN`, which is passed to the auth probe through its environment and never printed.

Each code set records itself in its `REVISION` file as `key=value` lines: `sha`, `ref`,
`subject`, `deployed_at` (UTC), `node`, and `status`:
- `staged`: built, not yet proven;
- `ok`: passed its smoke test;
- `failed`: failed it while the other code came up.

`REVISION` moves with its code, so `~/relay/REVISION` names what actually runs. Code without a
`REVISION` is code that was live before this script existed. `--rollback` accepts a
`~/relay.prev` whose status is `ok`, or that has no `REVISION`, and refuses anything else.

Each run writes its lines to `~/.cache/relay-deploy/last-run.log`, ending with
`relay-deploy: finished: exit <code>`, and appends one line to `~/.cache/relay-deploy/history.log`.
A lock (`~/.cache/relay-deploy/lock`, holding the pid) keeps runs from overlapping. A lock left
by a run that no longer exists is removed automatically.

Exit codes (every failure maps to one of these; git or npm errors do not pass their own codes through):

| Code | Meaning |
|---|---|
| 0 | deployed, rolled back, or already live |
| 1 | failed or interrupted before anything live changed, including any git/npm/build error |
| 2 | usage error |
| 3 | deployed, but the auth probe failed or timed out |
| 4 | smoke test failed; the code that was live before is live again, `~/relay.prev` as before |
| 5 | smoke test failed and the previous code did not come up either |
| 6 | the swap itself failed midway (filesystem error); the message names the dirs to inspect |

Exit 5 usually means the cause is outside the code: network, DNS, Discord, or `.env`. The
message lists what to check, in order:
1. `curl -sS -m 5 -o /dev/null -w '%{http_code}\n' https://discord.com/api/v10/gateway` (expect 200);
2. `launchctl print gui/<uid>/com.rancho.relay`;
3. the newest lines of `~/relay/logs/relay.error.log` and `relay.log`;
4. that `~/relay/.env` sets `DISCORD_BOT_TOKEN`.

Once the cause is fixed, `launchctl kickstart -k` the service and re-run the deploy.

Paths and the label come from the launchd plist and `$HOME`. They can be overridden with
`RELAY_*` variables (see the script header). Other flags: `--force`, `--build-only`,
`--no-fetch`, `--no-wait`, `--no-auth-probe`.

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
