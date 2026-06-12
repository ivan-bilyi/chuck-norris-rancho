/**
 * Nightly reconcile scheduler.
 *
 * At RELAY_RECONCILE_CRON (default 03:00 daily) every registered project is
 * triaged:
 *   - fresh activity since the last successful reconcile -> spawn `/reconcile`
 *     in the project's live session (the session distills itself into
 *     .chuck/memory/), then close the session so the morning starts fresh;
 *   - session idle for more than STALE_DAYS -> close it without a run
 *     (nothing worth distilling);
 *   - everything else -> skip.
 *
 * Relay stays a dumb pipe: the prompt is the fixed string `/reconcile`; all
 * distillation logic lives in the reconcile skill on the Mac.
 */

import * as cron from 'node-cron';
import * as db from './db.js';
import * as router from './router.js';
import * as notify from './notify.js';

const DEFAULT_CRON = '0 3 * * *';
const STALE_DAYS = 7;
const DAY_MS = 24 * 60 * 60 * 1000;

export type ReconcileAction = 'run' | 'close_stale' | 'skip';

export interface ProjectFacts {
  reconcileEnabled: boolean;
  hasClaudeSession: boolean;
  /** Last non-reconcile spawn (SQLite UTC timestamp) or null. */
  lastActivityAt: string | null;
  /** Last successful reconcile spawn (SQLite UTC timestamp) or null. */
  lastReconcileAt: string | null;
}

/** SQLite CURRENT_TIMESTAMP is UTC without a zone marker — parse it as UTC. */
export function parseSqliteUtc(ts: string): number {
  return Date.parse(ts.replace(' ', 'T') + 'Z');
}

export function decideAction(facts: ProjectFacts, now: Date): ReconcileAction {
  if (!facts.reconcileEnabled) return 'skip';
  if (!facts.hasClaudeSession) return 'skip';

  const activityMs = facts.lastActivityAt
    ? parseSqliteUtc(facts.lastActivityAt)
    : null;
  const fresh =
    activityMs !== null && now.getTime() - activityMs <= STALE_DAYS * DAY_MS;

  if (!fresh) return 'close_stale';

  const newSinceReconcile =
    !facts.lastReconcileAt ||
    parseSqliteUtc(facts.lastActivityAt!) >
      parseSqliteUtc(facts.lastReconcileAt);

  return newSinceReconcile ? 'run' : 'skip';
}

function gatherFacts(project: db.Project): ProjectFacts {
  const session = db.getSessionByProjectId(project.id);
  return {
    reconcileEnabled: project.reconcile_enabled,
    hasClaudeSession: !!session?.claude_session_id,
    lastActivityAt: db.getLastActivityAt(project.id),
    lastReconcileAt: db.getLastSuccessfulReconcileAt(project.id),
  };
}

let nightlyRunning = false;

export async function runNightly(): Promise<void> {
  if (nightlyRunning) {
    console.log(
      `[${new Date().toISOString()}] Reconcile: previous nightly run still in progress, skipping`,
    );
    return;
  }
  nightlyRunning = true;

  try {
    const projects = db.getAllProjects();
    console.log(
      `[${new Date().toISOString()}] Reconcile: nightly run over ${projects.length} project(s)`,
    );

    // Sequential on purpose: one fat resumed session in memory at a time.
    for (const project of projects) {
      try {
        const action = decideAction(gatherFacts(project), new Date());

        if (action === 'skip') {
          console.log(
            `[${new Date().toISOString()}] Reconcile: ${project.name} — skip`,
          );
          continue;
        }

        if (action === 'close_stale') {
          const session = db.getSessionByProjectId(project.id);
          if (session) {
            db.updateSessionClaudeId(session.id, null);
            db.updateSessionStatus(session.id, 'idle');
          }
          console.log(
            `[${new Date().toISOString()}] Reconcile: ${project.name} — closed stale session without a run`,
          );
          continue;
        }

        console.log(
          `[${new Date().toISOString()}] Reconcile: ${project.name} — running`,
        );
        const result = await router.handleReconcile(project);

        if (result.success) {
          const report = result.result.trim();
          if (report) {
            await notify
              .sendToProjectChannel(project.name, report, 'info')
              .catch((err) =>
                console.error(
                  `[${new Date().toISOString()}] Reconcile: failed to post report for ${project.name}:`,
                  err,
                ),
              );
          }
        } else {
          await notify
            .sendToProjectChannel(
              project.name,
              `Nightly reconcile failed: ${result.error || 'unknown error'}. Session kept as is.`,
              'error',
            )
            .catch((err) =>
              console.error(
                `[${new Date().toISOString()}] Reconcile: failed to post error for ${project.name}:`,
                err,
              ),
            );
        }
      } catch (err) {
        console.error(
          `[${new Date().toISOString()}] Reconcile: unexpected error for ${project.name}:`,
          err,
        );
      }
    }

    console.log(`[${new Date().toISOString()}] Reconcile: nightly run done`);
  } finally {
    nightlyRunning = false;
  }
}

let task: cron.ScheduledTask | null = null;

export function start(): void {
  const expr = process.env.RELAY_RECONCILE_CRON || DEFAULT_CRON;
  if (!cron.validate(expr)) {
    console.error(
      `[${new Date().toISOString()}] Reconcile: invalid RELAY_RECONCILE_CRON "${expr}", falling back to "${DEFAULT_CRON}"`,
    );
  }
  const effective = cron.validate(expr) ? expr : DEFAULT_CRON;

  task = cron.schedule(effective, () => {
    runNightly().catch((err) =>
      console.error(
        `[${new Date().toISOString()}] Reconcile: nightly run crashed:`,
        err,
      ),
    );
  });

  console.log(
    `[${new Date().toISOString()}] Reconcile scheduler started (cron: ${effective})`,
  );
}

export function stop(): void {
  if (task) {
    task.stop();
    task = null;
  }
}
