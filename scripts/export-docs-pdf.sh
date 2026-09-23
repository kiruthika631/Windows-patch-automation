#!/bin/bash
# Export docs/index.html + fleet-status.json to a downloadable PDF.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

python3 ./scripts/export-docs-pdf.py
