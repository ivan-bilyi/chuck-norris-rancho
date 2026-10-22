import { spawn as cpSpawn, ChildProcess, execFile } from 'child_process';

export interface SpawnOptions {
  prompt: string;
  projectPath: string;
  claudeSessionId: string | null;
  skipPermissions: boolean;
  identity?: string | null;
  resumeSession?: boolean;
  kind?: string;
}

export interface SpawnResult {
  success: boolean;
  result: string;
  claudeSessionId: string;
  costUsd: string | null;
  error?: string;
  peakRssKb: number | null;
  durationMs: number;
  resumed: boolean;
}

const running = new Map<string, ChildProcess>();

const DEFAULT_TIMEOUT_MS = Number(process.env.RELAY_TASK_TIMEOUT_MS) || 600_000;

// 0 disables RSS sampling; negative values treated as disabled.
const RSS_SAMPLE_INTERVAL_MS = (() => {
  const raw = process.env.RELAY_RSS_SAMPLE_INTERVAL_MS;
  if (raw === undefined) return 5000;
  const n = Number(raw);
  if (!Number.isFinite(n) || n < 0) return 5000;
  return Math.floor(n);
})();

const MAX_CONCURRENT_CLAUDE = (() => {
  const raw = process.env.RELAY_MAX_CONCURRENT_CLAUDE;
  if (raw === undefined) return 2;
  const n = Number(raw);
  if (!Number.isFinite(n) || n < 1) {
    console.error(
      `[${new Date().toISOString()}] Invalid RELAY_MAX_CONCURRENT_CLAUDE=${raw}; clamping to 1`,
    );
    return 1;
  }
  return Math.floor(n);
})();

let activeSpawns = 0;
const slotWaiters: Array<() => void> = [];

function tryClaimSlot(): boolean {
  if (activeSpawns < MAX_CONCURRENT_CLAUDE) {
    activeSpawns++;
    return true;
  }
  return false;
}

function awaitSlot(): Promise<void> {
  return new Promise<void>((resolve) => {
    slotWaiters.push(resolve);
  });
}

function releaseSlot(): void {
  const next = slotWaiters.shift();
  if (next) {
    // Slot transferred to next waiter; activeSpawns unchanged.
    next();
  } else {
    activeSpawns--;
  }
}

/**
 * Readable failure text for a CLI run. With `--output-format json` an API or
 * auth error comes back as a JSON result body on stdout (`is_error: true`,
 * the message in `result`); other failures (e.g. an unknown `--resume` id)
 * are plain text on stderr. Use the message, not the raw JSON body: the body
 * carries unrelated fields such as `session_id`.
 */
function failureDetail(stdout: string, stderr: string): string {
  let jsonMessage = '';
  try {
    const parsed = JSON.parse(stdout);
    if (typeof parsed?.result === 'string') jsonMessage = parsed.result.trim();
  } catch {
    // stdout is not a JSON body
  }
  const detail =
    [stderr.trim(), jsonMessage].filter(Boolean).join('\n') || stdout.trim();
  return detail.slice(0, 2000);
}

function sampleRss(pid: number): Promise<number | null> {
  return new Promise((resolve) => {
    execFile('ps', ['-o', 'rss=', '-p', String(pid)], (err, stdout) => {
      if (err) return resolve(null);
      const kb = parseInt(stdout.trim(), 10);
      resolve(Number.isFinite(kb) ? kb : null);
    });
  });
}

export function spawnClaude(options: SpawnOptions): Promise<SpawnResult> {
  if (tryClaimSlot()) {
    return spawnClaudeImpl(options);
  }
  return awaitSlot().then(() => spawnClaudeImpl(options));
}

function spawnClaudeImpl(options: SpawnOptions): Promise<SpawnResult> {
  const resumed = options.resumeSession ?? options.claudeSessionId != null;
  const kind = options.kind || 'user';
  const startedAt = Date.now();

  let released = false;
  const release = () => {
    if (released) return;
    released = true;
    releaseSlot();
  };

  const args: string[] = ['-p', options.prompt, '--output-format', 'json'];
  if (resumed && options.claudeSessionId) {
    args.push('--resume', options.claudeSessionId);
  }
  if (options.skipPermissions) {
    args.push('--dangerously-skip-permissions');
  }

  const identityEnv: Record<string, string> = options.identity
    ? { CHUCK_WIKI_CLIENT_IDENTITY: options.identity }
    : {};

  let child: ChildProcess;
  try {
    child = cpSpawn('claude', args, {
      cwd: options.projectPath,
      env: {
        ...process.env,
        ...identityEnv,
        PATH: `/opt/homebrew/bin:/opt/homebrew/opt/node@22/bin:${process.env.PATH || ''}`,
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
  } catch (err) {
    release();
    return Promise.resolve({
      success: false,
      result: '',
      claudeSessionId: options.claudeSessionId || '',
      costUsd: null,
      error: `Failed to spawn claude: ${(err as Error).message}`,
      peakRssKb: null,
      durationMs: Date.now() - startedAt,
      resumed,
    });
  }

  running.set(options.projectPath, child);

  let stdout = '';
  let stderr = '';
  let peakRssKb = 0;
  let sampleTimer: ReturnType<typeof setInterval> | null = null;

  if (RSS_SAMPLE_INTERVAL_MS > 0 && child.pid) {
    const tick = async () => {
      if (!child.pid) return;
      const kb = await sampleRss(child.pid);
      if (kb !== null && kb > peakRssKb) peakRssKb = kb;
    };
    tick().catch(() => {});
    sampleTimer = setInterval(() => {
      tick().catch(() => {});
    }, RSS_SAMPLE_INTERVAL_MS);
  }

  const stopSampling = () => {
    if (sampleTimer) {
      clearInterval(sampleTimer);
      sampleTimer = null;
    }
  };

  child.stdout!.on('data', (chunk: Buffer) => {
    stdout += chunk.toString();
  });
  child.stderr!.on('data', (chunk: Buffer) => {
    stderr += chunk.toString();
  });

  return new Promise<SpawnResult>((resolve) => {
    const timeout = setTimeout(() => {
      console.error(
        `[${new Date().toISOString()}] Timeout: killing claude process for ${options.projectPath}`,
      );
      child.kill('SIGTERM');
      setTimeout(() => {
        if (!child.killed) child.kill('SIGKILL');
      }, 5000);
    }, DEFAULT_TIMEOUT_MS);

    // Safety: if close/error never fires (zombie or hang), force-release after timeout + grace
    // so the global cap doesn't deadlock.
    const safetyTimer = setTimeout(() => {
      if (released) return;
      console.error(
        `[${new Date().toISOString()}] Safety release: PID ${child.pid} did not emit close within timeout+grace for ${options.projectPath}`,
      );
      clearTimeout(timeout);
      stopSampling();
      running.delete(options.projectPath);
      release();
      resolve({
        success: false,
        result: '',
        claudeSessionId: options.claudeSessionId || '',
        costUsd: null,
        error: 'Process stuck after timeout; slot force-released',
        peakRssKb: peakRssKb > 0 ? peakRssKb : null,
        durationMs: Date.now() - startedAt,
        resumed,
      });
    }, DEFAULT_TIMEOUT_MS + 10_000);

    child.on('close', (code) => {
      clearTimeout(timeout);
      clearTimeout(safetyTimer);
      stopSampling();
      running.delete(options.projectPath);

      const durationMs = Date.now() - startedAt;
      const peak = peakRssKb > 0 ? peakRssKb : null;

      let out: SpawnResult;
      if (code === 0) {
        try {
          const parsed = JSON.parse(stdout);
          out = parsed.is_error === true
            ? {
                // The CLI reported an API/auth error in its JSON body. That is
                // a failure even with exit code 0: callers must not treat it
                // as a completed turn (the nightly reconcile would close the
                // session as if it had been distilled).
                success: false,
                result: '',
                claudeSessionId: options.claudeSessionId || '',
                costUsd: null,
                error: `Claude reported an error: ${failureDetail(stdout, stderr)}`,
                peakRssKb: peak,
                durationMs,
                resumed,
              }
            : {
                success: true,
                result: parsed.result || '(no result)',
                claudeSessionId: parsed.session_id || options.claudeSessionId || '',
                costUsd: parsed.total_cost_usd?.toString() || null,
                peakRssKb: peak,
                durationMs,
                resumed,
              };
        } catch {
          out = {
            success: true,
            result: stdout.trim() || '(empty output)',
            claudeSessionId: options.claudeSessionId || '',
            costUsd: null,
            peakRssKb: peak,
            durationMs,
            resumed,
          };
        }
      } else {
        out = {
          success: false,
          result: '',
          claudeSessionId: options.claudeSessionId || '',
          costUsd: null,
          error: `Claude exited with code ${code}: ${failureDetail(stdout, stderr)}`,
          peakRssKb: peak,
          durationMs,
          resumed,
        };
      }

      console.log(
        `[${new Date().toISOString()}] spawn finished pid=${child.pid} project=${options.projectPath} kind=${kind} resumed=${resumed} peak_rss_kb=${peak ?? 'n/a'} duration_ms=${durationMs} success=${out.success}`,
      );

      release();
      resolve(out);
    });

    child.on('error', (err) => {
      clearTimeout(timeout);
      clearTimeout(safetyTimer);
      stopSampling();
      running.delete(options.projectPath);
      release();
      resolve({
        success: false,
        result: '',
        claudeSessionId: options.claudeSessionId || '',
        costUsd: null,
        error: `Failed to spawn claude: ${err.message}`,
        peakRssKb: peakRssKb > 0 ? peakRssKb : null,
        durationMs: Date.now() - startedAt,
        resumed,
      });
    });
  });
}

export function isRunning(projectPath: string): boolean {
  const child = running.get(projectPath);
  return !!child && !child.killed;
}

export function killByProject(projectPath: string): boolean {
  const child = running.get(projectPath);
  if (child && !child.killed) {
    child.kill('SIGTERM');
    return true;
  }
  return false;
}

export function killAll(timeoutMs = 30_000): Promise<void> {
  const entries = [...running.entries()];
  if (entries.length === 0) return Promise.resolve();

  for (const [, child] of entries) {
    if (!child.killed) child.kill('SIGTERM');
  }

  return new Promise((resolve) => {
    const check = setInterval(() => {
      if (running.size === 0) {
        clearInterval(check);
        resolve();
      }
    }, 500);

    setTimeout(() => {
      for (const [, child] of running) {
        if (!child.killed) child.kill('SIGKILL');
      }
      clearInterval(check);
      resolve();
    }, timeoutMs);
  });
}
