#!/bin/bash
# Copy refreshed screenshots into the isolated gh-pages worktree and commit.
#
#   ./publish-screenshots.sh <screenshots-dir> [commit-message]
#
# The site lives on an orphan `gh-pages` branch. This creates a temporary
# worktree for it, replaces the PNGs under assets/, commits, and removes the
# worktree. It does NOT push — review the commit first, then `git push origin gh-pages`.
set -euo pipefail
set +m

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
SRC="${1:?usage: publish-screenshots.sh <screenshots-dir> [message]}"
MSG="${2:-chore(site): refresh screenshots}"

if [ ! -d "$SRC" ]; then
  echo "No such screenshots dir: $SRC" >&2
  exit 1
fi
if ! git -C "$ROOT" show-ref --verify --quiet refs/heads/gh-pages; then
  echo "gh-pages branch not found in $ROOT" >&2
  exit 1
fi

WT="$(mktemp -d)/pm-pages"
git -C "$ROOT" worktree add "$WT" gh-pages >/dev/null
trap 'git -C "$ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || true' EXIT

cp "$SRC"/*.png "$WT/assets/"
git -C "$WT" add -A
if git -C "$WT" diff --cached --quiet; then
  echo "No screenshot changes to commit."
  exit 0
fi
git -C "$WT" commit -m "$MSG"
echo "Committed to gh-pages: $MSG"
echo "Push with: git -C \"$ROOT\" push origin gh-pages"
