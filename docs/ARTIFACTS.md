# Vitrina — self-hosted artifact pipeline for Rancho

Status: **implemented, in production** on Whitemini (launchd `com.rancho.vitrina`).
Design: Chuck (main), 2026-08-29. Landed in this repo the same day with tests, the
`publish-artifact` skill and the sharing model completed.

Goal: reproduce the claude.ai "artifact" experience (Claude writes a self-contained
interactive page, publishes it, hands back a link) but hosted on Rancho, with sharing
controls that *we* own, usable by every project Chuck for its own Discord channel.

## 1. Why not claude.ai artifacts

In the Relay/CLI context there is no Artifact tool — the only outbound path is Relay's
attachment contract (`[attach: <path>]` / `![](path)`), which posts a *file*: no
interactivity, no stable URL, no revocation, 25 MB cap, re-upload on every re-share.
Web-UI artifacts put sharing policy on Anthropic's side and give the family an account wall.

Vitrina keeps the artifact *pipeline* (one self-contained HTML page authored by the model)
and replaces the *hosting and sharing* half with Rancho.

## 2. Hosting

Tailscale Funnel on `whitemini` with a real public TLS cert. The family needs **no
Tailscale, no account, no VPN** — a plain HTTPS link opens in any browser, including
Discord's in-app browser.

```
https://whitemini.impala-symmetric.ts.net        (Funnel)       -> 127.0.0.1:4477  public server
https://whitemini.impala-symmetric.ts.net:8444   (tailnet only) -> 127.0.0.1:4477  same server, no funnel
127.0.0.1:4478                                   (loopback only)                   admin API
```

The earlier umio mounts on 443/8443/10000 were retired (their launchd plists are
`.disabled`), so Vitrina owns the whole 443 host rather than a `/v` path mount — that
resolves open decision #1 from the design. The `:8444` mount carries no
`Tailscale-Funnel-Request` header, which is how the server tells "tailnet" from "internet".

Two ports on purpose: Funnel proxies from 127.0.0.1, so a loopback check cannot
distinguish the internet from a local caller. Public and admin therefore listen on
*different* ports, and only 4477 is ever mounted.

```
tailscale serve status                                          # inspect
tailscale serve --bg --https=8444 http://127.0.0.1:4477         # tailnet-only mount (one-time)
tailscale serve --https=8444 off                                # roll back
```
(`tailscale` on the Mac is the daemon's CLI, `/opt/homebrew/bin/tailscale --socket=/var/run/tailscaled.socket`;
while the GUI app still runs instead, it is `/Applications/Tailscale.app/Contents/MacOS/Tailscale`. See RUNBOOK
"Tailscale daemon". Both mounts are declared in `infra/tailscaled/cutover.sh` (`SERVE_MOUNTS`), which
re-creates them.)

## 3. Components

```
Chuck (any channel)
  |  skill: publish-artifact   (~/.claude/skills/ — user-level, every session has it)
  v
vitrina CLI  (~/bin/vitrina, /opt/homebrew/bin/vitrina)
  |  POST http://127.0.0.1:4478/api/…   X-Vitrina-Token: …
  v
vitrina service  (Node 22, zero deps, launchd com.rancho.vitrina)
  |-- store  ~/vitrina/data/store/<id>/{index.html, source.*, a/*, meta.json}
  |-- log    ~/vitrina/data/hits.log   (JSONL access log)
  |-- GET    /v/<slug>, /p/<token>, /_a/*     public, via Funnel
  |-- POST   Relay :4466 /notify              cross-channel sharing
  v
Discord: Chuck posts the URL into its own channel; Discord unfurls the OG card.
```

Nothing in Relay changed. Vitrina is a sibling service — Relay stays a dumb pipe and
Vitrina talks to it only through the existing loopback notify API.

Storage is the filesystem, not SQLite: one directory per artifact with `meta.json`, an
in-memory index built at boot. At family scale that is simpler and needs no native module.

## 4. URL scheme

```
/v/<slug>          artifact shell: OG meta + header + sandboxed iframe
/v/<slug>/raw      the artifact document itself (CSP applied here)
/v/<slug>/a/*      artifact-local assets (--asset)
/v/<slug>/code     POST target of the passcode form
/p/<portal-token>  a person's portal: everything currently shared with them
/_a/*              vendored react / react-dom / babel / tailwind, immutable cache
/healthz           200 (launchd / deploy probe)
anything else      404 text/plain — no listing, no enumeration
```

`slug` = 22 chars base62 = 128 bits of entropy. The URL **is** the capability.

## 5. Sharing model

| `--vis`   | who can open                          | mechanism                                                        |
|-----------|---------------------------------------|------------------------------------------------------------------|
| `link`    | anyone holding the URL                | unguessable slug — **default**                                   |
| `code`    | URL + 4–8-digit code                  | HttpOnly cookie scoped to `/v/<slug>`, 30 d                      |
| `portal`  | members of `--to` who opened their portal | `/p/<token>` sets a 1-year HttpOnly cookie; gate checks membership |
| `private` | Ivan only                             | 404 on the funnel; opens only via the `:8444` tailnet mount      |

Audiences live in `~/.config/rancho/vitrina.json`: `people` (name, Discord id, one
`portal_token` each) and `audiences` (`family`, `parents`, `ivan`, `oksana`, `mari`, …).
Every artifact carries `--to <audience>` (default `family`) — it decides whose portal lists
it, and for `portal` visibility who may open it at all. Each family member bookmarks exactly
one portal link and always sees the current set of things shared with them.

Every artifact also carries `--project <name>` (auto-detected from cwd against
`~/relay/relay.db`), so main-channel Chuck can `vitrina list` / `revoke` across all projects.

Lifecycle: default TTL 90 days (`--expires 30d|12w|6m|never|<ISO date>`). Expired artifacts
serve a friendly Ukrainian 410 page (and drop off portals); `vitrina extend` resurrects
them; the files are purged 30 days after expiry by the daily sweep (`vitrina gc` runs it now).
`vitrina revoke` deletes immediately — the link becomes a 404.

`--update <slug>` keeps the URL, bumps the version, and keeps every field you don't
re-specify (title, vis, audience, code, expiry) — so a link posted in June shows August data.

## 6. CLI surface

```
vitrina publish --file <path> [--type html|react|md] --title "…" [--desc "…"]
                [--to <audience>] [--vis link|code|private|portal] [--code 1234]
                [--expires 90d|never] [--project <name>] [--update <slug>]
                [--asset <path>]…  [--share <project>]  [--json]
vitrina list [--project <name>] [--to <audience>] [--json]
vitrina info <slug>              vitrina hits <slug>
vitrina revoke <slug>            vitrina extend <slug> <90d|never>
vitrina share <slug> --to-channel <project> [--text "…"]
vitrina portals                  vitrina gc
```

`publish` prints the URL on stdout (and a one-line summary on stderr); `--json` prints
`{slug, url, version, expires_at, vis, audience}`. Type is inferred from the extension
(`.md` → md, `.jsx`/`.js` → react, else html). For `private` the URL uses the tailnet origin.

## 7. Artifact types

- `html` — one self-contained file, stored verbatim. Inline CSS/JS only; no CDN (CSP).
- `react` — the model writes only the component (`function App() { … }`, hooks are in
  scope); Vitrina wraps it with React 18 + Tailwind + Babel-standalone from `/_a/`
  (**vendored**, see `vitrina/assets/README.md` — offline-proof and immune to a CDN
  changing under old artifacts).
- `md` — markdown rendered server-side (headings, emphasis, code, lists, quotes, tables,
  links, images, rules) into a readable article template. The cheap 80 % case.

The shell at `/v/<slug>` renders the OG card and embeds the artifact in
`<iframe sandbox="allow-scripts allow-popups allow-forms">`: Discord gets a proper unfurl,
and artifact code runs in an opaque origin where it cannot touch portal or passcode cookies.

## 8. Security

The funnel is the open internet; assume scanners find the hostname.

- Write API is loopback-only on a never-funnelled port + shared token from
  `~/.config/rancho/vitrina.env` (0600). Every Chuck runs as the same uid, so publisher
  auth is not a boundary between agents — the boundary that matters is the *read* side.
- CSP on artifacts: `default-src <own origins>; connect-src 'none'; frame-ancestors 'self';
  base-uri 'none'; form-action 'none'` (+ `unsafe-inline`/`unsafe-eval` for in-browser
  Babel). `connect-src 'none'` means a buggy or malicious artifact cannot exfiltrate anything.
- `nosniff`, `Referrer-Policy: no-referrer`, `X-Robots-Tag: noindex`; the only cookies are
  the scoped passcode cookie and the portal cookie, both HttpOnly + Secure + SameSite=Lax.
- Rate limit 120 req/min/IP (`X-Forwarded-For` from Funnel); unknown paths 404 flat.
- `private` answers 404 on the funnel *before* the expiry check, so existence never leaks.
- 5 MB cap per artifact; asset names are basename-only; path traversal rejected.
- Every open logged (`hits.log`: timestamp, per-slug-salted hashed IP, UA, funnel flag) so a
  leaked link is visible, not silent — `vitrina hits <slug>`.

Residual risk, accepted: a `link` artifact is readable by anyone who obtains the URL —
Discord's CDN, a forwarded screenshot, a synced clipboard. Use `code` or `portal` for
anything that would matter if it leaked, `private` for anything that must not.

## 9. Layout

```
chuck-norris-rancho/
  vitrina/src/{index,config,store,render,public,admin}.js
  vitrina/bin/vitrina                 the CLI (symlinked to ~/bin and /opt/homebrew/bin)
  vitrina/templates/{shell,react,md,portal,message}.html
  vitrina/assets/{react,react-dom,babel,tailwind}.js   vendored
  vitrina/test/*.test.js              node --test (CI + test-n-merge)
  infra/vitrina.plist                 com.rancho.vitrina, KeepAlive
  scripts/vitrina-deploy.sh           run ON the Mac: rsync → ~/vitrina, symlinks, launchd
  docs/ARTIFACTS.md                   this file
chuck-norris-agent/skills/publish-artifact/SKILL.md   → copied to ~/.claude/skills/ on the Mac
~/.config/rancho/vitrina.env          VITRINA_TOKEN, ports, VITRINA_BASE_URL, VITRINA_TAILNET_URL, VITRINA_DATA, VITRINA_TTL_DAYS
~/.config/rancho/vitrina.json         people + audiences
~/vitrina/{data/,logs/}               runtime (never in git)
```

Distribution to every Chuck is the user-level skill directory — `~/.claude/skills/` is
shared by all sessions on this machine, so registering the skill once gives every project
channel the capability with no per-project CLAUDE.md edits (same mechanism as `chuck-wiki`
and `reconcile`). `relay/templates/project-claude.md` mentions it for discoverability.

## 10. Operations

```bash
# deploy (on the Mac)
ssh rancho 'cd ~/chuck-norris-rancho && git pull && scripts/vitrina-deploy.sh'
# install/update the skill (from the agent repo)
scp -r skills/publish-artifact rancho:~/.claude/skills/
# health / logs
ssh rancho 'curl -s localhost:4477/healthz; tail -20 ~/vitrina/logs/vitrina.log'
# audit across all projects
ssh rancho 'vitrina list'          # or from main-channel Chuck
# tests (locally)
cd vitrina && npm test
```

Add a family member: edit `~/.config/rancho/vitrina.json` (name, discord_id, a fresh
`portal_token` of 20+ base62 chars, membership in audiences); no restart needed — the file
is re-read on change. Hand them `vitrina portals` → their `/p/<token>` link to bookmark.

## 11. Decisions (formerly open)

1. **Whole host, not `/v` path mount** — umio no longer occupies 443; simpler URLs, and
   `/p/`, `/_a/` live alongside. `:8444` tailnet-only serves `private`.
2. **Default = `link` + 90-day TTL.** `code`/`portal` are opt-in per artifact.
3. **Portals ship in v1** — one bookmark per person; the portal cookie is also what makes
   `portal` visibility a real gate rather than a label.

Not done (deliberately): headless-screenshot `og:image` (Discord unfurls title/description
fine), SQLite (filesystem index suffices), per-Chuck auth (same uid anyway).
