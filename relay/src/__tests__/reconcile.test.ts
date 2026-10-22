import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { decideAction, parseSqliteUtc, ProjectFacts } from '../reconcile.js';
import * as db from '../db.js';

const NOW = new Date('2026-06-12T03:00:00Z');

function facts(overrides: Partial<ProjectFacts>): ProjectFacts {
  return {
    reconcileEnabled: true,
    hasClaudeSession: true,
    lastActivityAt: null,
    lastReconcileAt: null,
    ...overrides,
  };
}

describe('parseSqliteUtc', () => {
  it('parses SQLite CURRENT_TIMESTAMP format as UTC', () => {
    expect(parseSqliteUtc('2026-06-12 03:00:00')).toBe(NOW.getTime());
  });
});

describe('decideAction', () => {
  it('skips when reconcile is disabled for the project', () => {
    const f = facts({
      reconcileEnabled: false,
      lastActivityAt: '2026-06-11 13:00:00',
    });
    expect(decideAction(f)).toBe('skip');
  });

  it('skips when there is no live claude session', () => {
    const f = facts({
      hasClaudeSession: false,
      lastActivityAt: '2026-06-11 13:00:00',
    });
    expect(decideAction(f)).toBe('skip');
  });

  it('runs when there is fresh activity and no reconcile yet', () => {
    const f = facts({ lastActivityAt: '2026-06-11 13:00:00' });
    expect(decideAction(f)).toBe('run');
  });

  it('runs when fresh activity is newer than the last reconcile', () => {
    const f = facts({
      lastActivityAt: '2026-06-11 13:00:00',
      lastReconcileAt: '2026-06-10 03:00:00',
    });
    expect(decideAction(f)).toBe('run');
  });

  it('skips when the last reconcile already covered the latest activity', () => {
    const f = facts({
      lastActivityAt: '2026-06-10 13:00:00',
      lastReconcileAt: '2026-06-11 03:00:00',
    });
    expect(decideAction(f)).toBe('skip');
  });

  it('runs (never closes) an old session whose activity was never distilled', () => {
    // e.g. reconcile failed for more than a week in a row: the memory is
    // still in the session, so distill it rather than drop it.
    const f = facts({
      lastActivityAt: '2026-06-01 13:00:00',
      lastReconcileAt: '2026-05-20 03:00:00',
    });
    expect(decideAction(f)).toBe('run');
  });

  it('keeps a session that has no logged activity at all', () => {
    const f = facts({ lastActivityAt: null });
    expect(decideAction(f)).toBe('skip');
  });

  it('never returns an action that closes a session without a run', () => {
    const cases: Partial<ProjectFacts>[] = [
      { lastActivityAt: null },
      { lastActivityAt: '2026-01-01 00:00:00' },
      { lastActivityAt: '2026-01-01 00:00:00', lastReconcileAt: '2026-06-11 03:00:00' },
      { lastActivityAt: '2026-06-11 13:00:00', lastReconcileAt: '2026-06-10 03:00:00' },
    ];
    for (const c of cases) {
      expect(['run', 'skip']).toContain(decideAction(facts(c)));
    }
  });
});

describe('db reconcile support', () => {
  beforeEach(() => {
    db.initialize(':memory:');
  });

  afterEach(() => {
    db.close();
  });

  it('new projects have reconcile enabled by default', () => {
    const p = db.createProject('ch-1', '/tmp/proj', 'test');
    expect(p.reconcile_enabled).toBe(true);
  });

  it('setProjectReconcileEnabled toggles the flag', () => {
    db.createProject('ch-1', '/tmp/proj', 'test');
    expect(db.setProjectReconcileEnabled('test', false)).toBe(true);
    expect(db.getProjectByName('test')!.reconcile_enabled).toBe(false);
    expect(db.setProjectReconcileEnabled('test', true)).toBe(true);
    expect(db.getProjectByName('test')!.reconcile_enabled).toBe(true);
  });

  it('setProjectReconcileEnabled returns false for unknown project', () => {
    expect(db.setProjectReconcileEnabled('nope', false)).toBe(false);
  });

  it('getSessionByProjectId returns null before any session exists', () => {
    const p = db.createProject('ch-1', '/tmp/proj', 'test');
    expect(db.getSessionByProjectId(p.id)).toBeNull();
    db.getOrCreateSession(p.id);
    expect(db.getSessionByProjectId(p.id)).not.toBeNull();
  });

  it('activity and reconcile timestamps come from spawn_log by kind', () => {
    const p = db.createProject('ch-1', '/tmp/proj', 'test');
    expect(db.getLastActivityAt(p.id)).toBeNull();
    expect(db.getLastSuccessfulReconcileAt(p.id)).toBeNull();

    db.insertSpawnLog({
      projectId: p.id,
      claudeSessionId: 'sess-1',
      kind: 'user',
      resumed: false,
      durationMs: 100,
      peakRssKb: null,
      success: true,
      costUsd: null,
    });
    db.insertSpawnLog({
      projectId: p.id,
      claudeSessionId: 'sess-1',
      kind: 'reconcile',
      resumed: true,
      durationMs: 100,
      peakRssKb: null,
      success: false,
      costUsd: null,
    });

    // user spawn counts as activity; failed reconcile does not count as a reconcile
    expect(db.getLastActivityAt(p.id)).not.toBeNull();
    expect(db.getLastSuccessfulReconcileAt(p.id)).toBeNull();

    db.insertSpawnLog({
      projectId: p.id,
      claudeSessionId: 'sess-1',
      kind: 'reconcile',
      resumed: true,
      durationMs: 100,
      peakRssKb: null,
      success: true,
      costUsd: null,
    });
    expect(db.getLastSuccessfulReconcileAt(p.id)).not.toBeNull();
  });
});
