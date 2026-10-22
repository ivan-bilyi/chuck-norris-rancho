/**
 * Regression: a session's memory must survive transient failures.
 *
 * Faults are injected at the process boundary: `child_process.spawn` returns
 * fake `claude` processes that fail the way the real CLI does. Everything
 * above that boundary is real: spawner, router, the nightly reconcile
 * scheduler, and SQLite (in memory). The assertions read the session id back
 * from the database.
 *
 * Rule under test: the session id is cleared only when the CLI answers a
 * `--resume` with its explicit "No conversation found" error, and never on
 * the nightly reconcile path (where a failed night keeps the session for the
 * next night's retry).
 */

const savedEnv = vi.hoisted(() => {
  const keys = [
    'RELAY_RSS_SAMPLE_INTERVAL_MS',
    'RELAY_MAX_CONCURRENT_CLAUDE',
    'RELAY_TASK_TIMEOUT_MS',
  ] as const;
  const saved = Object.fromEntries(keys.map((k) => [k, process.env[k]]));
  process.env.RELAY_RSS_SAMPLE_INTERVAL_MS = '0';
  process.env.RELAY_MAX_CONCURRENT_CLAUDE = '999';
  // Short task timeout so the "hung process" fault exercises the real kill path.
  process.env.RELAY_TASK_TIMEOUT_MS = '200';
  return saved;
});

import { describe, it, expect, vi, beforeEach, afterEach, afterAll } from 'vitest';
import { EventEmitter } from 'events';
import { PassThrough } from 'stream';

vi.mock('child_process', () => ({
  spawn: vi.fn(),
  execFile: vi.fn(),
}));
vi.mock('../notify.js', () => ({
  setDiscordClient: vi.fn(),
  sendToProjectChannel: vi.fn().mockResolvedValue(undefined),
}));

import { spawn as cpSpawn } from 'child_process';
import * as db from '../db.js';
import * as notify from '../notify.js';
import { handleMessage, handleAutoReview, clearBuffers } from '../router.js';
import { runNightly } from '../reconcile.js';

afterAll(() => {
  for (const [k, v] of Object.entries(savedEnv)) {
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
});

// ── Fake `claude` processes ───────────────────────────────────

interface Fault {
  /** Exit code; null = killed by a signal. */
  code: number | null;
  stdout?: string;
  stderr?: string;
  /** Never exits on its own (the spawner's timeout must kill it). */
  hang?: boolean;
}

const SID = '5f0c1e2a-7b3d-4c9e-8a10-000000000001';

/** The CLI's JSON result body for an API/auth error (`--output-format json`). */
const apiError = (message: string): string =>
  JSON.stringify({
    type: 'result',
    subtype: 'success',
    is_error: true,
    result: message,
    session_id: SID,
    total_cost_usd: 0,
  });

const ok = (sessionId: string, text = 'ok'): Fault => ({
  code: 0,
  stdout: JSON.stringify({
    type: 'result',
    subtype: 'success',
    is_error: false,
    result: text,
    session_id: sessionId,
    total_cost_usd: 0.01,
  }),
});

/** Exact CLI text (claude 2.1.x) for `--resume` with an unknown session id. */
const NO_CONVERSATION: Fault = {
  code: 1,
  stderr: `No conversation found with session ID: ${SID}\n`,
};

const TRANSIENT: Array<[string, Fault]> = [
  ['timeout (hung process killed by the spawner)', { code: null, hang: true }],
  ['HTTP 500', { code: 1, stdout: apiError('API Error: 500 {"type":"error","error":{"type":"api_error","message":"Internal server error"}}') }],
  ['HTTP 529 overloaded', { code: 1, stdout: apiError('API Error: 529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}') }],
  ['rate limit (429)', { code: 1, stdout: apiError('API Error: 429 {"type":"error","error":{"type":"rate_limit_error","message":"Rate limited"}}') }],
  ['usage limit reported with exit code 0', { code: 0, stdout: apiError('Claude AI usage limit reached|1792720800') }],
  ['expired OAuth token', { code: 1, stdout: apiError('Failed to authenticate. API Error: 401 OAuth token has expired.') }],
  ['subscription access disabled', { code: 1, stdout: apiError('Your organization has disabled Claude subscription access.') }],
  ['"session expired" on stderr', { code: 1, stderr: 'Error: session expired, please retry\n' }],
  ['"not found" on stderr', { code: 1, stderr: 'Error: MCP server config not found\n' }],
  ['crash with a truncated JSON body', { code: 1, stdout: `{"session_id":"${SID}","result":"partial` }],
];

let queue: Fault[] = [];
let spawnArgs: string[][] = [];

function fakeChild(f: Fault) {
  const child = new EventEmitter() as EventEmitter & {
    stdout: PassThrough;
    stderr: PassThrough;
    killed: boolean;
    pid: number;
    kill: (signal?: string) => boolean;
  };
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  child.killed = false;
  child.pid = 4242;
  child.kill = () => {
    child.killed = true;
    setImmediate(() => child.emit('close', null));
    return true;
  };
  if (!f.hang) {
    setImmediate(() => {
      if (f.stdout) child.stdout.write(f.stdout);
      if (f.stderr) child.stderr.write(f.stderr);
      setImmediate(() => child.emit('close', f.code));
    });
  }
  return child;
}

function resumeArg(args: string[]): string | null {
  const i = args.indexOf('--resume');
  return i === -1 ? null : args[i + 1];
}

// ── Fixtures ──────────────────────────────────────────────────

let project: db.Project;

function liveSessionId(): string | null {
  return db.getSessionByProjectId(project.id)!.claude_session_id;
}

function fakeMessage() {
  return {
    content: 'hi',
    channel: {
      id: 'ch-1',
      messages: { fetch: vi.fn() },
      sendTyping: vi.fn().mockResolvedValue(undefined),
    },
    author: { username: 'u', displayName: 'U' },
    member: { displayName: 'U' },
    reference: null,
    messageSnapshots: null,
    attachments: new Map(),
    stickers: new Map(),
    embeds: [],
    reply: vi.fn().mockResolvedValue(undefined),
    react: vi.fn().mockResolvedValue(undefined),
    reactions: { cache: { get: vi.fn().mockReturnValue(undefined) } },
    client: { user: { id: 'bot' } },
  } as any;
}

beforeEach(() => {
  queue = [];
  spawnArgs = [];
  vi.mocked(cpSpawn).mockImplementation(((_cmd: string, args: string[]) => {
    spawnArgs.push(args);
    const next = queue.shift();
    if (!next) throw new Error('test: unexpected extra claude spawn');
    return fakeChild(next);
  }) as any);
  vi.mocked(notify.sendToProjectChannel).mockClear();

  clearBuffers();
  db.initialize(':memory:');
  project = db.createProject('ch-1', '/tmp/relay-test-project', 'test');
  const session = db.getOrCreateSession(project.id);
  db.updateSessionClaudeId(session.id, SID);
  // A day of conversation that no reconcile has distilled yet.
  db.insertSpawnLog({
    projectId: project.id,
    claudeSessionId: SID,
    kind: 'user',
    resumed: true,
    durationMs: 1000,
    peakRssKb: null,
    success: true,
    costUsd: null,
  });
});

afterEach(() => {
  db.close();
});

// ── User messages ─────────────────────────────────────────────

describe('user message path', () => {
  it.each(TRANSIENT)('%s: the session id survives, no fresh session', async (_name, fault) => {
    queue = [fault];
    const msg = fakeMessage();

    await handleMessage(msg);

    expect(spawnArgs).toHaveLength(1);
    expect(resumeArg(spawnArgs[0])).toBe(SID);
    expect(liveSessionId()).toBe(SID);
    expect(msg.reply).toHaveBeenCalledTimes(1); // the error is shown, not hidden
  });

  it('the explicit "No conversation found" error starts a fresh session', async () => {
    queue = [NO_CONVERSATION, ok('fresh-session')];

    await handleMessage(fakeMessage());

    expect(spawnArgs).toHaveLength(2);
    expect(resumeArg(spawnArgs[0])).toBe(SID);
    expect(resumeArg(spawnArgs[1])).toBeNull();
    expect(liveSessionId()).toBe('fresh-session');
  });

  it('the explicit error clears the dead id even if the fresh retry fails', async () => {
    queue = [NO_CONVERSATION, TRANSIENT[1][1]];

    await handleMessage(fakeMessage());

    expect(spawnArgs).toHaveLength(2);
    expect(liveSessionId()).toBeNull();
  });
});

// ── Auto-review ───────────────────────────────────────────────

describe('auto-review path', () => {
  it.each(TRANSIENT)('%s: the session id survives', async (_name, fault) => {
    queue = [fault];

    const result = await handleAutoReview(project, 'proposal.md');

    expect(result.success).toBe(false);
    expect(spawnArgs).toHaveLength(1);
    expect(liveSessionId()).toBe(SID);
  });

  it('the explicit "No conversation found" error starts a fresh session', async () => {
    queue = [NO_CONVERSATION, ok('fresh-session')];

    await handleAutoReview(project, 'proposal.md');

    expect(spawnArgs).toHaveLength(2);
    expect(liveSessionId()).toBe('fresh-session');
  });
});

// ── Nightly reconcile ─────────────────────────────────────────

describe('nightly reconcile path', () => {
  it.each(TRANSIENT)(
    '%s: the session is kept and the next night distills it',
    async (_name, fault) => {
      // Night 1: the reconcile run fails.
      queue = [fault];
      await runNightly();

      expect(spawnArgs).toHaveLength(1);
      expect(resumeArg(spawnArgs[0])).toBe(SID);
      expect(liveSessionId()).toBe(SID);
      expect(notify.sendToProjectChannel).toHaveBeenCalledWith(
        'test',
        expect.stringContaining('Session kept'),
        'error',
      );

      // Night 2: the same session is resumed, distilled, and only then closed.
      queue = [ok(SID, 'memory updated')];
      await runNightly();

      expect(spawnArgs).toHaveLength(2);
      expect(resumeArg(spawnArgs[1])).toBe(SID);
      expect(spawnArgs[1]).toContain('/reconcile');
      expect(liveSessionId()).toBeNull();
      expect(notify.sendToProjectChannel).toHaveBeenLastCalledWith(
        'test',
        'memory updated',
        'info',
      );
    },
  );

  it('never retries in a fresh session and never clears, even on "No conversation found"', async () => {
    queue = [NO_CONVERSATION];

    await runNightly();

    expect(spawnArgs).toHaveLength(1);
    expect(resumeArg(spawnArgs[0])).toBe(SID);
    expect(liveSessionId()).toBe(SID);
  });

  it('a session whose activity is already distilled is left alone', async () => {
    db.insertSpawnLog({
      projectId: project.id,
      claudeSessionId: SID,
      kind: 'reconcile',
      resumed: true,
      durationMs: 1000,
      peakRssKb: null,
      success: true,
      costUsd: null,
    });
    // Logged after the activity, so it covers it (same-second ties count as covered).

    await runNightly();

    expect(spawnArgs).toHaveLength(0);
    expect(liveSessionId()).toBe(SID);
  });
});
