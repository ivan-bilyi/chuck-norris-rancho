# Relay

Thin Discord-to-Claude-Code transport layer. Part of the Rancho (chuck-norris-rancho) infrastructure project.

## Architecture

Discord message -> Relay (discord.js bot) -> child_process.spawn('claude', [...]) -> Parse JSON -> Reply to Discord

Relay is a dumb pipe. All intelligence lives inside Claude Code sessions, driven by per-project CLAUDE.md files.

## Tech Stack

- Node.js 22, TypeScript, CommonJS modules
- discord.js 14 (bot framework)
- better-sqlite3 (synchronous SQLite)
- dotenv (env file loading)

## Project Structure

- `src/index.ts` — entry point, bootstrap, graceful shutdown
- `src/bot.ts` — Discord client, slash commands, event handlers
- `src/db.ts` — SQLite schema and queries (projects, sessions)
- `src/spawner.ts` — Claude CLI process spawning, JSON output parsing, timeout
- `src/router.ts` — Message routing: channel -> project -> session -> spawn -> reply
- `src/reconcile.ts` — Nightly reconcile scheduler (node-cron): distill sessions into `.chuck/memory/`, close them
- `src/discord-format.ts` — Output formatting and 2000-char message splitting

## Build & Run

```bash
npm run build   # compile TypeScript to dist/
npm start       # run compiled JS
npm run dev     # run TypeScript directly with tsx (development)
```

## Conventions

- All database operations are synchronous (better-sqlite3)
- IDs use `crypto.randomUUID()`
- Logging via `console.log`/`console.error` with ISO timestamps
- No `--bare` flag on Claude CLI (preserves CLAUDE.md auto-discovery, OAuth, plugins)
- Working directory for Claude is set via spawn `cwd` option, not a CLI flag
- One task at a time per project (reject if busy)
- Session resumed via `--resume <session_id>` for conversation continuity
- Sessions are bounded: the nightly reconcile (default 03:00, `RELAY_RECONCILE_CRON`) resumes each active session one last time with the fixed prompt `/reconcile` (the skill on the Mac distills the conversation into the project's `.chuck/memory/` files), posts the skill's short report to the channel, and nulls `claude_session_id` so the morning starts fresh. Sessions idle for >7 days are closed without a run. Per-project opt-out: `/project reconcile <name> false`.

## Key Constraints

Relay MUST NOT:
- Create its own agent loop
- Modify prompts or add system prompts
- Use Claude API directly
- Use `--bare` flag (breaks OAuth subscription auth and CLAUDE.md discovery)

## Outgoing attachment contract

Claude can post files back to Discord by placing one of these in its text output — Relay parses them in `discord-format.ts:extractAttachments`, strips the markers, and attaches the files to the reply (last chunk if split).

- `![alt](<path>)` — markdown image, used for inline images. Alt text is kept, marker is removed.
- `[attach: <path>]` — explicit marker, used for any file type (images, PDFs, docs, etc.). Removed from text.

Rules enforced by Relay:
- Paths are resolved relative to the project's `cwd`; absolute paths are accepted only when they resolve **under** the project directory (traversal rejected).
- `http://`, `https://`, and `data:` URLs in `![](…)` are left untouched — Discord auto-embeds them.
- Files must exist and be ≤ 25 MB.
- Maximum 10 attachments per reply (Discord hard limit).
- Missing / oversize / out-of-project paths are dropped silently (logged to stderr).
