#!/bin/bash
# Remove Cursor Agent from GitHub contributors by rewriting commit SHAs and force-pushing.
# Safe to run only when remote commit messages already have no Co-authored-by trailers.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "ERROR: Commit or stash local changes before running this script."
  git status --short
  exit 1
fi

echo "=== Step 1: remove filter-branch backup refs ==="
rm -rf .git/refs/original/
git for-each-ref --format='delete %(refname)' refs/original 2>/dev/null | git update-ref --stdin || true

echo "=== Step 2: strip any Cursor co-author trailers (main only) ==="
FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f \
  --msg-filter 'grep -v "^Co-authored-by: Cursor <cursoragent@cursor.com>$"' \
  main

echo "=== Step 3: rewrite all commit SHAs ==="
HOOK="${ROOT}/.git/hooks/prepare-commit-msg"
if [[ -f "$HOOK" ]]; then
  mv "$HOOK" "${HOOK}.disabled"
fi
trap '[[ -f "${HOOK}.disabled" ]] && mv "${HOOK}.disabled" "$HOOK"' EXIT

GIT_SEQUENCE_EDITOR=: git rebase --root --committer-date-is-author-date main

echo "=== Step 4: verify ==="
if git log main --format='%B' | grep -qi 'co-authored-by: Cursor'; then
  echo "ERROR: Cursor co-author trailers still present."
  exit 1
fi
echo "OK: no Cursor co-author trailers on main"
git log -1 --format='Latest commit: %h %an <%ae> %s'

echo
echo "=== Step 5: force push (requires network + GitHub auth) ==="
echo "Run:"
echo "  git push --force origin main"
echo
echo "After push, hard-refresh GitHub. The Contributors sidebar may take up to 24h to update."
