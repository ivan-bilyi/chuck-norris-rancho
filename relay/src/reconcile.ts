/**
 * Nightly reconcile scheduler.
 *
 * At RELAY_RECONCILE_CRON (default 03:00 daily) every registered project is
 * triaged:
 *   - a live session with activity not yet covered by a successful reconcile
 *     (however old) -> spawn `/reconcile` in that session (the session distills
 *     itself into .chuck/memory/), then close the session so the morning
 *     starts fresh;
 *   - everything else -> skip, leaving the session as it is.
 *
 * Memory safety: a session is only ever closed after a successful distill.
 * A failed run keeps the session, and the next night tries again, because its
 * activity is still newer than the last successful reconcile.
 *
 * Relay stays a dumb pipe: the prompt is the fixed string `/reconcile`; all
 * distillation logic lives in the reconcile skill on the Mac.
 */

import * as cron from 'node-cron';
import * as db from './db.js';
import * as router from './router.js';
import * as notify from './notify.js';

const DEFAULT_CRON = '0 3 * * *';

export type ReconcileAction = 'run' | 'skip';

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

export function decideAction(facts: ProjectFacts): ReconcileAction {
  if (!facts.reconcileEnabled) return 'skip';
  if (!facts.hasClaudeSession) return 'skip';
  // No logged activity: nothing known to distill. Keep the session as is.
  if (!facts.lastActivityAt) return 'skip';

  const undistilled =
    !facts.lastReconcileAt ||
    parseSqliteUtc(facts.lastActivityAt) > parseSqliteUtc(facts.lastReconcileAt);

  return undistilled ? 'run' : 'skip';
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
        const action = decideAction(gatherFacts(project));

        if (action === 'skip') {
          console.log(
            `[${new Date().toISOString()}] Reconcile: ${project.name} — skip`,
          );
          continue;
        }

        console.log(
          `[${new Date().toISOString()}] Reconcile: ${project.name} — running`,
        );
        const result = await router.handleReconcile(project);

        if (!result) {
          console.log(
            `[${new Date().toISOString()}] Reconcile: ${project.name} — no live session any more, skip`,
          );
          continue;
        }

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
              `Nightly reconcile failed: ${result.error || 'unknown error'}. Session kept; the next nightly run retries.`,
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
