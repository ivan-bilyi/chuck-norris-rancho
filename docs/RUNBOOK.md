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
5. Tailscale: `brew install tailscale` (builds from source on macOS 14), clone this repo, then `sudo bash infra/tailscaled/cutover.sh --hostname <name>` and approve the login URL it prints (see [Tailscale daemon](#tailscale-daemon))

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
   0600 backup `.env.bak.<timestamp>`, and tightens older backups to 0600. The verification
   has a 120 s timeout (`RELAY_TOKEN_VERIFY_TIMEOUT`). If the script is interrupted, it
   removes its temp file, which holds the token. It also says whether `.env` changed and
   whether Relay still needs `launchctl kickstart -k`.

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

# funnel / tailnet mounts (the daemon's CLI; see Tailscale daemon)
ssh rancho 'tailscale --socket=/var/run/tailscaled.socket serve status'   # needs Homebrew on PATH (see Tailscale daemon)
# while the GUI app still runs instead: /Applications/Tailscale.app/Contents/MacOS/Tailscale serve status
```

Config: `~/.config/rancho/vitrina.env` (token, ports, base URLs), `~/.config/rancho/vitrina.json`
(people + audiences + portal tokens). Data: `~/vitrina/data/` (back up with the Relay db).

## Tailscale daemon

The Mac's Tailscale node should be the open-source `tailscaled`, run as a system LaunchDaemon. It
starts at boot, before anyone logs in. The standalone GUI app (bundle `io.tailscale.ipn.macsys`, a
system network extension) connects only inside a logged-in GUI session, and after a reboot it can
come back "Stopped". That takes down the tailnet path and anything bound to the tailnet address.
`infra/tailscaled/cutover.sh` moves the host from the app to the daemon, and `--rollback` moves it
back.

Commands below assume a shell with Homebrew on PATH. Over non-interactive SSH, run
`eval "$(<path to brew> shellenv)"` first.

### What runs

- Installed with upstream's `tailscaled install-system-daemon`, run from the Homebrew formula
  `tailscale`. It copies the binary to `/usr/local/bin/tailscaled` and writes
  `/Library/LaunchDaemons/com.tailscale.tailscaled.plist` with `RunAtLoad`. State lives in
  `/Library/Tailscale/tailscaled.state`; the CLI socket is `/var/run/tailscaled.socket`.
- CLI: `"$(brew --prefix)/bin/tailscale" --socket=/var/run/tailscaled.socket <command>`. The login
  user is the daemon's operator, so no sudo is needed. **Always pass `--socket`.** Without it,
  the CLI on macOS talks to the GUI app's backend whenever that backend answers.
- Prefs: `--accept-routes --accept-dns --operator=<login user> --hostname=<name>`. No exit node,
  no advertised routes, no Tailscale SSH.
- Serve/funnel: port 443 is public through Funnel, and port 8444 is tailnet-only; both serve
  `/` from `http://127.0.0.1:4477` (Vitrina). They are declared in `SERVE_MOUNTS` at the top of the
  script, and the script re-creates them whenever the node's config differs.
- The GUI app stays installed for the rollback, switched off in four ways:
  - `down`, so its WantRunning is off;
  - `TailscaleStartOnLogin` is false in its defaults domain;
  - its login-item helper (the bundle id of the helper under
    `Contents/Library/LoginItems`) is disabled for the user with `launchctl disable gui/<uid>/<id>`,
    which persists;
  - the app is quit.
- With `--accept-dns` the daemon writes `/etc/resolver/<tailnet suffix>` for MagicDNS. When the
  tailnet overrides local DNS, it also installs a global resolver through SystemConfiguration.
  This host serves the LAN's DNS, so check `scutil --dns` after a change.

### Before the cutover

1. **Homebrew formula, well before the window**, as the login user (brew refuses root):
   `brew install tailscale`. Homebrew has no `arm64_sonoma` bottle for `tailscale` or for `go`, so
   on macOS 14 it builds Go and then tailscale from source. That takes a long time on this
   machine. `--preflight` reports a missing formula.
2. **A known-good starting point.** A first cutover (no daemon installed yet) starts only when
   both of these hold; `--preflight` reports NOT READY and the cutover refuses otherwise:
   - the GUI app, if installed, answers and is `Running` with a tailnet IPv4. A silent or
     stopped app means the starting state is unknown: bring the tailnet up on the app first;
   - no process other than Tailscale's own has a TCP listening socket, or any UDP socket, whose
     local address lies in `100.64.0.0/10` or `fd7a:115c:a1e0::/48`. Such a process fails while
     the address is gone. For example, AdGuard with its web UI on the tailnet address
     crash-loops, and the LAN falls back to unfiltered DNS. Binds to `127.0.0.1`, to the
     wildcard address or to LAN addresses pass. Fixing AdGuard's bind is homelab work. The check
     reads `lsof` as root, and it refuses when `lsof` lists no TCP listener at all.
3. An SSH session over the LAN (by the host's `.local` name), not over the tailnet: the tailnet
   path drops during the cutover.
4. Daytime, and a browser signed in to the tailnet's admin account, to approve the login URL and
   to do the admin-console steps.

### Cutover, in order

Every script command needs root: the person with the sudo password runs it. The orchestrating
session reads the log, which the login user owns.

1. **Preflight** (changes nothing on the host):
   `cd ~/chuck-norris-rancho && git pull --ff-only && sudo bash infra/tailscaled/cutover.sh --preflight`.
   It must end in `READY`. It records the GUI app's non-secret prefs in
   `~/.cache/tailscaled-cutover/gui-prefs.txt`: Hostname, RouteAll, CorpDNS, ShieldsUp,
   AdvertiseTags, AdvertiseRoutes, ExitNodeID and RunSSH. It also saves the serve config to
   `serve-config-<UTC>.json` in the same directory, and prints the GUI node's name and IPv4.
   Note the IPv4.
2. **Cutover**, detached so that a dropped session cannot stop it:
   `sudo bash infra/tailscaled/cutover.sh --hostname <name> --detach`, then
   `tail -F ~/.cache/tailscaled-cutover/last-run.log`. In order, it:
   1. checks the starting point;
   2. records the GUI prefs again;
   3. switches the app off (above);
   4. installs the daemon;
   5. runs `tailscale up`;
   6. re-creates serve/funnel;
   7. verifies.

   Use the old machine name for `<name>`.
3. **Approve the node.** The log shows `LOGIN NEEDED` and a login URL in a banner. Open it and
   sign in with the account that owns the old node. The script waits for up to 15 minutes
   (`TS_CUTOVER_LOGIN_TIMEOUT`, passed as `sudo TS_CUTOVER_LOGIN_TIMEOUT=<s> bash …`). If the
   tailnet requires device approval, approve the machine in the admin console as well.
4. The log shows `verified: …` and ends with `finished: exit 0`. The verified line names what was
   checked: the plist with `RunAtLoad` and the loaded job. That the daemon really comes up at
   boot is proven only by step 8. The new node is up, but it is registered under a new name
   (`<name>-1`) and a new IPv4.
5. **Admin console**, on the tailnet admin's side:
   1. Delete the old node: the GUI app's node, now offline, under the old name.
   2. Rename the new node to the old name: Edit machine name, with the name no longer generated
      from the OS hostname.
   3. Edit its IPv4 back to the old address noted in step 1. SSH config, links and DNS settings
      that use the address keep working.
   4. Disable key expiry for the node, so it never needs another login.
6. **Re-run the cutover command** (same arguments). A node's serve config is keyed by its DNS name,
   so after the rename the script re-creates the mounts under the restored name, then verifies.
   A second re-run changes nothing.
7. **Check from outside the host:** `ssh` over the tailnet reaches the old address, Vitrina's public
   Funnel URL opens from a phone off Wi-Fi, `:8444` opens from a tailnet device, and AdGuard
   answers (`dig @127.0.0.1 example.com`).
8. Later, a reboot with nobody logged in proves the point: the daemon comes up `Running` with no
   login. A reboot is a separate action that needs the owner's go.

Re-running is safe at any stage: each step checks first and acts only on drift. When a run fails
or is stopped by a signal, its output and `last-run.log` end with, in this order:
1. the state: `!!! Tailscale is DOWN on this host now …` when neither the app nor the daemon is
   `Running` (no tailnet, Funnel off), otherwise `state now: …`;
2. the rollback command, or `nothing on the host was changed`;
3. what failed;
4. `finished: exit <code>`.

If a cutover stopped part-way before the daemon was installed, the app is already off and a
re-run refuses, because the starting point is no longer known-good. Run `--rollback` first.

### Rollback

`sudo bash infra/tailscaled/cutover.sh --rollback --detach`, over the LAN.

1. **It first proves that the app can come back, and changes nothing until then.** The login
   user must have a GUI session (`launchctl print gui/<uid>`). The app is launched in that
   session and stays disconnected, and its backend must answer. If not, the rollback refuses and
   leaves the daemon running. Log in on the console or over Screen Sharing, then run it again.
2. `tailscaled uninstall-system-daemon` (stop, unload, remove the plist and the
   `/usr/local/bin/tailscaled` copy), then `tailscaled --cleanup`.
3. It re-enables the login-item helper and start on login.
4. A bare `tailscale up` on the app. A bare `up` only sets WantRunning, so the app's prefs stay
   exactly as they were.
5. It checks the serve mounts and verifies: `Running`, a tailnet IPv4, the prefs equal to
   `gui-prefs.txt`, the daemon gone, and the helper and start on login on.

If the old node was already deleted in the admin console, the app's backend shows `NeedsLogin`.
The rollback then runs `up --reset` with flags rebuilt from `gui-prefs.txt`, and the log shows
the login URL. An exit node cannot be restored from its recorded ID; the log says so if one was
set. The app then registers as a new node, so rename it and set its IPv4 as in step 5 of the
cutover. The daemon's state file stays, so a later cutover reuses the daemon's node.

### Operating the daemon

```bash
"$(brew --prefix)/bin/tailscale" --socket=/var/run/tailscaled.socket status        # operator: no sudo
"$(brew --prefix)/bin/tailscale" --socket=/var/run/tailscaled.socket serve status
sudo launchctl print system/com.tailscale.tailscaled          # state, pid, last exit code
sudo launchctl kickstart -k system/com.tailscale.tailscaled   # restart (the tailnet drops briefly)
```

- **Upgrade:** `brew upgrade tailscale` updates the CLI only. The daemon runs its own copy in
  `/usr/local/bin`. To move the daemon to the new version, run
  `sudo "$(brew --prefix)/bin/tailscaled" install-system-daemon` over the LAN. It restarts the
  daemon and keeps the state and the serve config. Then re-run the cutover command to verify.
- **Residual risk:** upstream's plist has `RunAtLoad` but no `KeepAlive`. If `tailscaled` crashes,
  it stays down until the next boot or a `kickstart`.
- Scripts and checks that read Tailscale state must use the daemon's CLI with `--socket`, not
  `/Applications/Tailscale.app/Contents/MacOS/Tailscale`. After the cutover, the app's binary
  reports the app's backend, which is stopped.

### Log and exit codes

`~/.cache/tailscaled-cutover/` holds:
- `last-run.log`: the last cutover or rollback, ending with
  `tailscaled-cutover: finished: exit <code>`. It is truncated only once the run holds the lock.
- `preflight.log`.
- `history.log`: one line per run.
- `gui-prefs.txt`.
- the `serve-config-<UTC>.json` snapshots.
- `detached.out`: stray output of a `--detach` run.

A lock in the same directory keeps runs from overlapping.

| Code | Meaning |
|---|---|
| 0 | done and verified, already in place, or (preflight) ready |
| 1 | failed or refused (the end of the output says the state, the rollback command and what failed), or (preflight) not ready |
| 2 | usage: missing `--hostname` before the daemon runs, not root, unknown argument |

## SSH Tunnel Cheat Sheet

```bash
# Syncthing GUI
ssh -L 8384:localhost:8384 rancho
```
