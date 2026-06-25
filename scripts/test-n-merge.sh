#!/bin/bash
# test-n-merge — the standard pipeline for landing a change.
#
# Run it from a feature branch with your change ALREADY committed. It:
#   1. runs the CI-equivalent checks locally (relay/: tsc --noEmit + vitest)
#   2. only if green: merges the branch into main, pushes main
#   3. deletes the feature branch (local + remote)
#
# Aborts (leaving you on the feature branch, nothing pushed) if checks fail,
# the tree is dirty, or you are on main. Mirrors .github/workflows/ci.yml so
# the local run is equivalent to the required `test` status check.
#
# Usage:  scripts/test-n-merge.sh
set -euo pipefail

MAIN="main"
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"

# --- guards ---------------------------------------------------------------
if [ "$BRANCH" = "$MAIN" ]; then
  echo "✗ On '$MAIN' — switch to a feature branch first." >&2
  exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "✗ Working tree is dirty — commit your changes before landing." >&2
  git status --short >&2
  exit 1
fi

# --- test (mirror ci.yml: working-directory relay) ------------------------
echo "▶ Checks in relay/ (tsc --noEmit + vitest)…"
(
  cd relay
  [ -d node_modules ] || npm ci   # deps changed? run `npm ci` in relay/ yourself
  npx tsc --noEmit
  npm test
)
echo "✓ Checks passed"

# --- merge ----------------------------------------------------------------
echo "▶ Merging '$BRANCH' → '$MAIN'…"
git fetch origin --quiet
git checkout "$MAIN"
git pull --ff-only origin "$MAIN"
git merge --no-edit "$BRANCH"
git push origin "$MAIN"

# --- cleanup --------------------------------------------------------------
echo "▶ Deleting feature branch '$BRANCH'…"
git branch -d "$BRANCH"
git push origin --delete "$BRANCH" 2>/dev/null || true

echo "✅ Landed: '$BRANCH' → '$MAIN' (tested, pushed, branch deleted)."
