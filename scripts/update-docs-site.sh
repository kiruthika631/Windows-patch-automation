#!/bin/bash
# Regenerate docs/fleet-status.json for the internal website.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "=== Updating website fleet status ==="
pwsh -NoProfile -File ./scripts/Update-DocsSite.ps1
echo "Website data refreshed: docs/fleet-status.json"

if command -v python3 >/dev/null 2>&1; then
  echo "=== Exporting website PDF ==="
  python3 ./scripts/export-docs-pdf.py || echo "Warning: PDF export failed (install: pip3 install xhtml2pdf)"
fi

echo "Open http://10.90.105.221:8080/ and hard-refresh (Ctrl+F5) to see changes."
echo "PDF download: http://10.90.105.221:8080/Windows-Patch-Automation-Guide.pdf"
