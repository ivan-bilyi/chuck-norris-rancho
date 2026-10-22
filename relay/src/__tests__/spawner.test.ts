// Disable RSS sampling and raise concurrency cap before spawner loads module-level config.
process.env.RELAY_RSS_SAMPLE_INTERVAL_MS = '0';
process.env.RELAY_MAX_CONCURRENT_CLAUDE = '999';

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { EventEmitter } from 'events';
import { PassThrough } from 'stream';

// Mock child_process before importing spawner
vi.mock('child_process', () => ({
  spawn: vi.fn(),
  execFile: vi.fn(),
}));

import { spawn as cpSpawn } from 'child_process';
import { spawnClaude, isRunning, killByProject } from '../spawner.js';

function createFakeChild() {
  const child = new EventEmitter() as EventEmitter & {
    stdout: PassThrough;
    stderr: PassThrough;
    killed: boolean;
    kill: ReturnType<typeof vi.fn>;
    pid: number;
  };
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  child.killed = false;
  child.kill = vi.fn((signal?: string) => {
    child.killed = true;
    return true;
  });
  child.pid = 12345;
  return child;
}

function mockSpawn(child: ReturnType<typeof createFakeChild>) {
  (cpSpawn as unknown as ReturnType<typeof vi.fn>).mockReturnValue(child);
}

describe('spawnClaude', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('builds correct args with minimal options', async () => {
    const child = createFakeChild();
    mockSpawn(child);

    const promise = spawnClaude({
      prompt: 'hello',
      projectPath: '/tmp/proj',
      claudeSessionId: null,
      skipPermissions: false,
    });

    expect(cpSpawn).toHaveBeenCalledWith(
      'claude',
      ['-p', 'hello', '--output-format', 'json'],
      expect.objectContaining({ cwd: '/tmp/proj' }),
    );

    // Emit valid JSON and close
    child.stdout.end(JSON.stringify({ result: 'ok', session_id: 's1' }));
    child.emit('close', 0);

    const result = await promise;
    expect(result.success).toBe(true);
  });

  it('adds --resume when claudeSessionId provided', async () => {
    const child = createFakeChild();
    mockSpawn(child);

    const promise = spawnClaude({
      prompt: 'hello',
      projectPath: '/tmp/proj',
      claudeSessionId: 'session-abc',
      skipPermissions: false,
    });

    expect(cpSpawn).toHaveBeenCalledWith(
      'claude',
      ['-p', 'hello', '--output-format', 'json', '--resume', 'session-abc'],
      expect.anything(),
    );

    child.stdout.end(JSON.stringify({ result: 'ok', session_id: 'session-abc' }));
    child.emit('close', 0);
    await promise;
  });

  it('skips --resume when resumeSession is explicitly false even if claudeSessionId is set', async () => {
    const child = createFakeChild();
    mockSpawn(child);

    const promise = spawnClaude({
      prompt: 'hello',
      projectPath: '/tmp/proj',
      claudeSessionId: 'session-abc',
      skipPermissions: false,
      resumeSession: false,
    });

    const args = (cpSpawn as unknown as ReturnType<typeof vi.fn>).mock.calls[0][1];
    expect(args).not.toContain('--resume');
    expect(args).not.toContain('session-abc');

    child.stdout.end(JSON.stringify({ result: 'ok', session_id: 'new-session' }));
    child.emit('close', 0);
    const result = await promise;
    expect(result.resumed).toBe(false);
  });

  it('reports peakRssKb null and durationMs on result when sampling disabled', async () => {
    const child = createFakeChild();
    mockSpawn(child);

    const promise = spawnClaude({
      prompt: 'hello',
      projectPath: '/tmp/proj',
      claudeSessionId: null,
      skipPermissions: false,
    });

    child.stdout.end(JSON.stringify({ result: 'ok' }));
    child.emit('close', 0);

    const result = await promise;
    expect(result.peakRssKb).toBeNull();
    expect(typeof result.durationMs).toBe('number');
    expect(result.durationMs).toBeGreaterThanOrEqual(0);
    expect(result.resumed).toBe(false);
  });

  it('adds --dangerously-skip-permissions when skipPermissions is true', async () => {
    const child = createFakeChild();
    mockSpawn(child);

    const promise = spawnClaude({
      prompt: 'hello',
      projectPath: '/tmp/proj',
      claudeSessionId: null,
      skipPermissions: true,
    });

    const args = (cpSpawn as unknown as ReturnType<typeof vi.fn>).mock.calls[0][1];
    expect(args).toContain('--dangerously-skip-permissions');

    child.stdout.end(JSON.stringify({ result: 'ok' }));
    child.emit('close', 0);
    await promise;
  });

  it('parses valid JSON on exit code 0', async () => {
    const child = createFakeChild();
    mockSpawn(child);

    const promise = spawnClaude({
      prompt: 'hello',
      projectPath: '/tmp/proj',
      claudeSessionId: null,
      skipPermissions: false,
    });

    const json = {
      result: 'Files modified',
      session_id: 'sess-1',
      total_cost_usd: 0.05,
    };
    child.stdout.end(JSON.stringify(json));
    child.emit('close', 0);

    const result = await promise;
    expect(result.success).toBe(true);
    expect(result.result).toBe('Files modified');
    expect(result.claudeSessionId).toBe('sess-1');
    expect(result.costUsd).toBe('0.05');
  });

  it('returns raw stdout on invalid JSON with exit code 0', async () => {
    const child = createFakeChild();
    mockSpawn(child);

    const promise = spawnClaude({
      prompt: 'hello',
      projectPath: '/tmp/proj',
      claudeSessionId: null,
      skipPermissions: false,
    });

    child.stdout.end('not json');
    child.emit('close', 0);

    const result = await promise;
    expect(result.success).toBe(true);
    expect(result.result).toBe('not json');
  });

  it('returns error on non-zero exit code', async () => {
    const child = createFakeChild();
    mockSpawn(child);

    const promise = spawnClaude({
      prompt: 'hello',
      projectPath: '/tmp/proj',
      claudeSessionId: null,
      skipPermissions: false,
    });

    child.stderr.end('something went wrong');
    child.emit('close', 1);

    const result = await promise;
    expect(result.success).toBe(false);
    expect(result.error).toContain('code 1');
    expect(result.error).toContain('something went wrong');
  });

  it('reports the message of a JSON error body, not the raw body', async () => {
    const child = createFakeChild();
    mockSpawn(child);

    const promise = spawnClaude({
      prompt: 'hello',
      projectPath: '/tmp/proj',
      claudeSessionId: 'session-abc',
      skipPermissions: false,
    });

    // Shape of the CLI's output for an API/auth failure with --output-format json.
    child.stdout.end(
      JSON.stringify({
        type: 'result',
        subtype: 'success',
        is_error: true,
        result: 'Failed to authenticate. API Error: 401 OAuth access token is invalid.',
        session_id: 'other-session',
      }),
    );
    child.emit('close', 1);

    const result = await promise;
    expect(result.success).toBe(false);
    expect(result.error).toBe(
      'Claude exited with code 1: Failed to authenticate. API Error: 401 OAuth access token is invalid.',
    );
    expect(result.error).not.toContain('session_id');
    expect(result.claudeSessionId).toBe('session-abc');
  });

  it('treats is_error:true as a failure even with exit code 0', async () => {
    const child = createFakeChild();
    mockSpawn(child);

    const promise = spawnClaude({
      prompt: 'hello',
      projectPath: '/tmp/proj',
      claudeSessionId: 'session-abc',
      skipPermissions: false,
    });

    child.stdout.end(
      JSON.stringify({ is_error: true, result: 'API Error: 529 Overloaded', session_id: 'x' }),
    );
    child.emit('close', 0);

    const result = await promise;
    expect(result.success).toBe(false);
    expect(result.error).toContain('API Error: 529 Overloaded');
    expect(result.claudeSessionId).toBe('session-abc');
  });

  it('passes the CLI "No conversation found" stderr text through', async () => {
    const child = createFakeChild();
    mockSpawn(child);

    const promise = spawnClaude({
      prompt: 'hello',
      projectPath: '/tmp/proj',
      claudeSessionId: 'session-abc',
      skipPermissions: false,
    });

    child.stderr.end('No conversation found with session ID: session-abc\n');
    child.emit('close', 1);

    const result = await promise;
    expect(result.success).toBe(false);
    expect(result.error).toBe(
      'Claude exited with code 1: No conversation found with session ID: session-abc',
    );
  });

  it('returns error on spawn error event', async () => {
    const child = createFakeChild();
    mockSpawn(child);

    const promise = spawnClaude({
      prompt: 'hello',
      projectPath: '/tmp/proj',
      claudeSessionId: null,
      skipPermissions: false,
    });

    child.emit('error', new Error('ENOENT'));

    const result = await promise;
    expect(result.success).toBe(false);
    expect(result.error).toContain('Failed to spawn claude');
    expect(result.error).toContain('ENOENT');
  });
});

describe('isRunning / killByProject', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('isRunning returns true while process is active', async () => {
    const child = createFakeChild();
    mockSpawn(child);

    const promise = spawnClaude({
      prompt: 'hello',
      projectPath: '/tmp/active',
      claudeSessionId: null,
      skipPermissions: false,
    });

    expect(isRunning('/tmp/active')).toBe(true);

    child.stdout.end('{}');
    child.emit('close', 0);
    await promise;

    expect(isRunning('/tmp/active')).toBe(false);
  });

  it('killByProject sends SIGTERM and returns true', async () => {
    const child = createFakeChild();
    mockSpawn(child);

    const promise = spawnClaude({
      prompt: 'hello',
      projectPath: '/tmp/killme',
      claudeSessionId: null,
      skipPermissions: false,
    });

    expect(killByProject('/tmp/killme')).toBe(true);
    expect(child.kill).toHaveBeenCalledWith('SIGTERM');

    child.stdout.end('');
    child.emit('close', 1);
    await promise;
  });

  it('killByProject returns false when no process exists', () => {
    expect(killByProject('/tmp/nonexistent')).toBe(false);
  });
});
