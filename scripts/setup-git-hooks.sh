#!/bin/bash
# Install a local hook so Cursor is never added as co-author on future commits.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

HOOK="${ROOT}/.git/hooks/prepare-commit-msg"
mkdir -p "$(dirname "$HOOK")"
cat > "$HOOK" <<EOF
#!/bin/bash
exec "${ROOT}/scripts/strip-cursor-coauthor.sh" "\$1"
EOF
chmod +x "$HOOK" "${ROOT}/scripts/strip-cursor-coauthor.sh"
echo "Installed ${HOOK}"
