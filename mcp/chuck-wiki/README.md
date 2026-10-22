# chuck-wiki-mcp

MCP (Model Context Protocol) server that exposes Chuck's Obsidian vault (`chuck-norris-wiki`) to Claude Code sessions — read + contribute.

Spec: [chuck-norris-agent/PRODUCT.md §3.2, §6.3](https://github.com/ivan-bilyi/chuck-norris-agent/blob/main/PRODUCT.md).

## Tools

### Read (any identity)
- `search_notes(query, scope?, since?, limit?)` — ranked fuzzy search
- `read_note(path)` — full content of one note
- `list_backlinks(path)` — files linking to the given note
- `recent(since, limit?)` — files modified since date
- `check_similarity(title, content?)` — dup-check before `propose_note`

### Contribute (Chuck + project sessions + workstations)
- `propose_note(target_path, content, frontmatter?, reason)` — queue into `proposals/` for review
- `append_observation(path, content)` — add `## Observation YYYY-MM-DD` to existing wiki page
- `contribute_artifact(type, title, content, tags?, source_ref?)` — save snippet/finding/artifact/observation to `sources/from-sessions/<type>/`

### Admin (Chuck @ #general / #wiki only)
- `integrate_proposal(proposal_id, target_path?, mode?)` — accept or merge a pending proposal
- `reject_proposal(proposal_id, reason)` — reject and delete

## Safety middleware

Every write tool:
1. Enforces permissions per `src/permissions.ts` (identity-based access matrix).
2. Scans content against `<vault>/_meta/policies/secret-patterns.txt` — match → reject.
3. Enforces rate limit (10 contributions/hour per identity).
4. Enforces max note size (50 KB).
5. Logs the call (accepted or rejected) to `<vault>/_meta/contributions-log.jsonl`.

## Install

```bash
cd mcp/chuck-wiki
npm install
npm run build
```

## Run

Two transport modes, switched by env `CHUCK_WIKI_MCP_MODE`:

### `stdio` (default, used by Chuck on Mac Mini)

Subprocess spawned per Claude Code session. Identity from env.

| Env | Required | Example |
|---|---|---|
| `CHUCK_WIKI_VAULT_PATH` | yes | `/Users/i.beliy/chuck-norris-wiki/vault` |
| `CHUCK_WIKI_CLIENT_IDENTITY` | yes (for writes) | `chuck-main`, `chuck-project-rancho` |
| `CHUCK_WIKI_DISCORD_WEBHOOK_URL` | optional | for auto-process notifications |

Register on the same machine via `claude mcp add chuck-wiki -e ... -- node dist/index.js`.

### `http` (centralized daemon for remote workstations)

Long-running daemon. Multiple clients connect over Tailscale. Identity per request via header.

| Env | Required | Default | Notes |
|---|---|---|---|
| `CHUCK_WIKI_MCP_MODE` | yes for http | `stdio` | set to `http` |
| `CHUCK_WIKI_VAULT_PATH` | yes | — | absolute path |
| `CHUCK_WIKI_MCP_SECRET` | yes (http) | — | shared bearer token |
| `CHUCK_WIKI_MCP_BIND` | no | `127.0.0.1` | use `0.0.0.0` for Tailscale |
| `CHUCK_WIKI_MCP_PORT` | no | `8765` | |
| `CHUCK_WIKI_DISCORD_WEBHOOK_URL` | optional | — | for auto-process notifications |

Per request, the server reads:
- `Authorization: Bearer <secret>` — must match `CHUCK_WIKI_MCP_SECRET` (else 401).
- `X-Chuck-Client: <identity>` — used for permission gating (else `unknown` = read-only).

Identity prefixes recognized by the access matrix:
- `chuck-main`, `chuck-wiki` → superuser (all tools)
- `chuck-project-*` → read + contribute (no admin)
- `workstation-*` → read + contribute (no admin)
- anything else → read-only

## Auto-process proposals (in `propose_note`)

When a `propose_note` write succeeds, the server immediately decides:

```
target_exists                     → PENDING_TARGET_EXISTS  (always user-decided)
normalized_score >= 2.0           → PENDING_DUP            (probable duplicate)
normalized_score >= 0.5           → PENDING_RELATED        (possibly related)
otherwise                         → AUTO_INTEGRATE         (move to target_path, delete proposal)
```

`normalized_score = raw_search_score / query_token_count` against the top hit across `wiki/` and `sources/`.

Thresholds in `src/config.ts` — tune as the vault grows.

On `AUTO_INTEGRATE`, the server posts `✅ auto-added [[…]] from <identity> — <TL;DR>` to the Discord webhook. On any `PENDING_*`, it posts `⚠️ proposal needs review: <path> — <reason>. /review-proposals`.

The webhook is fire-and-forget — failure to deliver doesn't fail the MCP call.

## Claude Code client config

### Stdio (Chuck on Mac Mini, identity injected by Relay per channel)

```bash
claude mcp add chuck-wiki --scope user \
  -e CHUCK_WIKI_VAULT_PATH=/Users/i.beliy/chuck-norris-wiki/vault \
  -- /opt/homebrew/bin/node /Users/i.beliy/chuck-norris-rancho/mcp/chuck-wiki/dist/index.js
```

### HTTP (any workstation, talks to Mac daemon over Tailscale)

```bash
claude mcp add --transport http chuck-wiki \
  http://whitemini:8765/mcp \
  -H "X-Chuck-Client: workstation-<host>" \
  -H "Authorization: Bearer <secret>" \
  --scope user
```

## Deploy (Mac Mini, http daemon)

Install path: `~/chuck-norris-rancho/mcp/chuck-wiki/`.

```bash
cd ~/chuck-norris-rancho/mcp/chuck-wiki
npm install && npm run build
```

launchd plist `~/Library/LaunchAgents/com.rancho.chuck-wiki-mcp.plist`:

```xml
<key>EnvironmentVariables</key>
<dict>
    <key>CHUCK_WIKI_MCP_MODE</key><string>http</string>
    <key>CHUCK_WIKI_MCP_BIND</key><string>0.0.0.0</string>
    <key>CHUCK_WIKI_MCP_PORT</key><string>8765</string>
    <key>CHUCK_WIKI_VAULT_PATH</key><string>/Users/i.beliy/chuck-norris-wiki/vault</string>
    <key>CHUCK_WIKI_MCP_SECRET</key><string>...</string>
    <key>CHUCK_WIKI_DISCORD_WEBHOOK_URL</key><string>https://discord.com/api/webhooks/...</string>
</dict>
<key>KeepAlive</key><true/>
<key>RunAtLoad</key><true/>
```

Bootstrap: `launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.rancho.chuck-wiki-mcp.plist`.

Get the Discord webhook URL via the `/webhook create` slash command in the target Discord channel (Relay registers it).

Tailscale = network perimeter. With `BIND=0.0.0.0` on a Tailscale-only Mac, only tailnet peers can reach the port.

## Dev

```bash
CHUCK_WIKI_VAULT_PATH=/path/to/test/vault \
CHUCK_WIKI_CLIENT_IDENTITY=workstation-dev \
npm run dev
```

Then talk stdio MCP to it (Claude Code, MCP Inspector, or custom client).

## Tests

```bash
npm test
```

(TODO: write vault/safety/permissions tests; tracked in step 4 follow-up.)
