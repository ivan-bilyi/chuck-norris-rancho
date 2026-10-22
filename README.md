# Rancho

Personal AI agent infrastructure powered by **Relay** — a thin Discord-to-Claude-Code transport layer running on Mac Mini M1, controlled via Discord.

## Architecture

```
Discord (phone/desktop)              Mac Mini M1 (via Tailscale VPN)
+------------------+                 +----------------------------------+
| User messages in |  Discord API    | Relay (Node.js, discord.js)      |
| project channels | <============> | -> child_process.spawn('claude') |
|                  |                 | -> parse JSON output             |
| Rancho repo      |  SSH (Tailscale)| -> reply to Discord              |
| scripts/         | --------------> |                                  |
| relay/           |                 | ~/relay/ (Relay bot)             |
|                  |  Syncthing      | ~/projects/ (dev projects)       |
| shared/          | <============> | ~/shared/ (synced files)         |
+------------------+                 +----------------------------------+
```

Relay is a dumb pipe. All intelligence lives inside native Claude Code CLI sessions, driven by per-project `CLAUDE.md` files.

## Quick Start

1. Prepare Mac: enable SSH, auto-login, energy settings, install Homebrew & Tailscale (see RUNBOOK)
2. From Windows: `bash scripts/setup-ssh.sh mac <TAILSCALE_IP>`
3. Deploy: `scp infra/setup-mac.sh rancho:/tmp/ && ssh rancho 'bash /tmp/setup-mac.sh'`
4. Configure: `ssh rancho "claude setup-token"` + fill `DISCORD_BOT_TOKEN` in `~/relay/.env`
5. Deploy Relay on the Mac, from the repo clone there: `ssh rancho 'cd ~/chuck-norris-rancho && git pull --ff-only && scripts/relay-deploy.sh'`
6. Test: `bash scripts/status.sh` + send Discord message

## Scripts

| Script | Description |
|--------|-------------|
| `infra/setup-mac.sh` | Full Mac Mini setup (Node.js, Claude CLI, Relay, launchd) |
| `scripts/relay-deploy.sh` | Deploy Relay (run **on** the Mac Mini from `~/chuck-norris-rancho`): build a git SHA outside `~/relay`, swap only the code, restart, smoke-test, record the SHA in `~/relay/REVISION`; automatic and one-command rollback. See [RUNBOOK](docs/RUNBOOK.md#relay-deploy) |
| `scripts/logs.sh` | Tail Relay logs (`error` option) |
| `scripts/restart.sh` | Restart Relay service |
| `scripts/status.sh` | Full system status |
| `scripts/setup-ssh.sh` | Configure SSH (`mac` target) |
| `scripts/test-n-merge.sh` | Test current feature branch (relay: tsc + vitest; vitrina: node --test), merge to `main`, push, delete branch |
| `scripts/vitrina-deploy.sh` | Deploy Vitrina (run **on** the Mac Mini from `~/chuck-norris-rancho`): mirror `vitrina/` to `~/vitrina`, install CLI + launchd, restart |

## Vitrina — self-hosted artifacts

`vitrina/` is a sibling service (launchd `com.rancho.vitrina`) that hosts self-contained
HTML/React/Markdown pages authored by any Chuck and serves them to the family over Tailscale
Funnel with sharing controls we own (`link` / `code` / `portal` / `private`, TTL, revoke).
Every Chuck session publishes with the `vitrina` CLI via the user-level `publish-artifact`
skill. See [docs/ARTIFACTS.md](docs/ARTIFACTS.md).

## Discord Commands

| Command | Description |
|---------|-------------|
| `/project add <name> <path> <channel>` | Register a project |
| `/project list` | List all projects |
| `/project remove <name>` | Unregister a project |
| `/status` | Show session status |

## File Exchange

- `shared/inbox/` — put files here for the agent to process
- `shared/outbox/` — agent puts completed files here

## Detailed docs

See [docs/RUNBOOK.md](docs/RUNBOOK.md) for full deployment guide and troubleshooting.
