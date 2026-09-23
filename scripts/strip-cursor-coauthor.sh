#!/bin/bash
# Remove Cursor co-author trailers from a commit message file (for git hooks).
set -euo pipefail
MSG_FILE="${1:?commit message file required}"
grep -v '^Co-authored-by: Cursor <cursoragent@cursor.com>$' "$MSG_FILE" > "${MSG_FILE}.tmp"
mv "${MSG_FILE}.tmp" "$MSG_FILE"
