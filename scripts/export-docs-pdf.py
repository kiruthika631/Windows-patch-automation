#!/usr/bin/env python3
"""Export the internal docs website to a downloadable PDF snapshot."""
from __future__ import annotations

import html
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
INDEX = DOCS / "index.html"
FLEET = DOCS / "fleet-status.json"
OUTPUT = DOCS / "Windows-Patch-Automation-Guide.pdf"


def esc(value) -> str:
    if value is None:
        return ""
    return html.escape(str(value))


def load_main_html() -> str:
    text = INDEX.read_text(encoding="utf-8")
    match = re.search(r"<main class=\"main\">(.*)</main>", text, re.DOTALL)
    if not match:
        raise RuntimeError("Could not find <main> content in docs/index.html")
    main_html = match.group(1)

    main_html = re.sub(
        r"<pre class=\"mermaid\">.*?</pre>",
        (
            "<p><strong>End-to-end flow:</strong> Validate environment, connect to vCenter, "
            "copy scripts into the guest, repair Windows Update if needed, run patch cycles "
            "(scan, install, reboot), verify convergence, then export compliance reports.</p>"
        ),
        main_html,
        flags=re.DOTALL,
    )
    main_html = re.sub(r"\s*style=\"[^\"]*\"", "", main_html)
    main_html = re.sub(r"<a [^>]+>", "", main_html)
    main_html = re.sub(r"</a>", "", main_html)
    return main_html


def build_inventory_html(data: dict) -> dict[str, str]:
    summary = data.get("summary") or {}
    items = data.get("inventory") or []
    generated = data.get("generatedAtDisplay") or data.get("generatedAtUtc") or "Unknown"

    compliant = [i for i in items if i.get("patchResult") == "Compliant"]
    banner = (
        f"VM inventory — {summary.get('trackedVms', len(items))} VM(s) tracked, "
        f"{len(compliant)} Compliant. Last refreshed: {generated}."
    )

    rows = []
    for item in items:
        last_run = item.get("lastRunDisplay") or "—"
        run_id = item.get("lastRunId") or ""
        if run_id:
            last_run = f"{run_id[:8]} · {last_run}"
        rows.append(
            "<tr>"
            f"<td>{esc(item.get('vmName'))}</td>"
            f"<td>{esc(item.get('ipAddress'))}</td>"
            f"<td>{esc(item.get('owner'))}</td>"
            f"<td>{esc(item.get('fqdn'))}</td>"
            f"<td>{esc(item.get('enabled'))}</td>"
            f"<td>{esc(item.get('patchResult'))}</td>"
            f"<td>{esc(item.get('updatesInstalled', 0))}</td>"
            f"<td>{esc(item.get('cycles', 0))}</td>"
            f"<td>{esc(last_run)}</td>"
            f"<td>{esc(item.get('notes'))}</td>"
            "</tr>"
        )

    return {
        "banner": banner,
        "generated": f"Last refreshed: {generated}",
        "compliant": esc(summary.get("compliantVms", 0)),
        "patching": esc(summary.get("patchingVms", 0)),
        "tracked": esc(summary.get("trackedVms", len(items))),
        "updates": esc(summary.get("totalUpdatesInstalled", 0)),
        "rows": "".join(rows) or '<tr><td colspan="10">No VMs yet.</td></tr>',
    }


def inject_fleet_status(main_html: str, fleet: dict) -> str:
    parts = build_inventory_html(fleet)
    main_html = re.sub(
        r'<div class="update-banner"[^>]*>.*?</div>',
        f'<div class="update-banner"><strong>{esc(parts["banner"])}</strong></div>',
        main_html,
        count=1,
        flags=re.DOTALL,
    )
    main_html = main_html.replace("Loading…", parts["generated"], 1)
    def replace_num(field: str, html: str, element_id: str) -> str:
        pattern = rf'(<div class="num[^"]*" id="{element_id}">).*?(</div>)'
        return re.sub(
            pattern,
            lambda m: m.group(1) + parts[field] + m.group(2),
            html,
            count=1,
            flags=re.DOTALL,
        )

    main_html = replace_num("compliant", main_html, "summary-compliant")
    main_html = replace_num("patching", main_html, "summary-patching")
    main_html = replace_num("tracked", main_html, "summary-tracked")
    main_html = replace_num("updates", main_html, "summary-updates")
    main_html = re.sub(
        r'(<tbody id="inventory-body">).*?(</tbody>)',
        lambda m: m.group(1) + parts["rows"] + m.group(2),
        main_html,
        count=1,
        flags=re.DOTALL,
    )
    return main_html


def wrap_pdf_document(body: str, generated: str) -> str:
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Windows Patch Automation Framework Guide</title>
  <style>
    @page {{
      size: A4;
      margin: 1.5cm;
    }}
    body {{
      font-family: Helvetica, Arial, sans-serif;
      font-size: 10pt;
      line-height: 1.45;
      color: #111;
    }}
    h1 {{ font-size: 20pt; margin: 0 0 8pt; }}
    h2 {{ font-size: 14pt; margin: 18pt 0 8pt; page-break-after: avoid; }}
    h3 {{ font-size: 11pt; margin: 12pt 0 6pt; page-break-after: avoid; }}
    p, li {{ margin: 0 0 8pt; }}
    ul, ol {{ margin: 0 0 10pt 18pt; }}
    pre, code {{
      font-family: Courier, monospace;
      font-size: 8.5pt;
      background: #f4f4f4;
      border: 1px solid #ddd;
    }}
    pre {{
      padding: 8pt;
      white-space: pre-wrap;
      word-wrap: break-word;
    }}
    code {{ padding: 1pt 3pt; }}
    table {{
      width: 100%;
      border-collapse: collapse;
      margin: 8pt 0 12pt;
      font-size: 8pt;
    }}
    th, td {{
      border: 1px solid #ccc;
      padding: 4pt 5pt;
      vertical-align: top;
    }}
    th {{ background: #efefef; }}
    .hero {{ margin-bottom: 14pt; }}
    .lead {{ font-size: 11pt; color: #333; }}
    .badges {{ margin-top: 8pt; }}
    .badge {{
      display: inline-block;
      border: 1px solid #bbb;
      border-radius: 10pt;
      padding: 2pt 8pt;
      margin-right: 6pt;
      font-size: 8pt;
    }}
    .update-banner {{
      background: #eef6ff;
      border: 1px solid #bcd;
      padding: 8pt;
      margin-bottom: 12pt;
    }}
    .score-grid {{
      width: 100%;
      margin: 8pt 0 12pt;
    }}
    .score-box {{
      display: inline-block;
      width: 23%;
      border: 1px solid #ccc;
      padding: 6pt;
      text-align: center;
      margin-right: 1%;
    }}
    .score-box .num {{ font-size: 16pt; font-weight: bold; }}
    .score-box .lbl {{ font-size: 8pt; color: #555; }}
    .footer {{
      margin-top: 18pt;
      padding-top: 8pt;
      border-top: 1px solid #ccc;
      font-size: 8pt;
      color: #555;
    }}
    section {{ page-break-inside: avoid; }}
  </style>
</head>
<body>
  <p style="font-size:8pt;color:#555;">Exported from http://10.90.105.221:8080/ on {esc(generated)}</p>
  {body}
  <div class="footer">
    Windows Patch Automation Framework · PDF export · Live site: http://10.90.105.221:8080/
  </div>
</body>
</html>"""


def export_pdf() -> Path:
    fleet = json.loads(FLEET.read_text(encoding="utf-8"))
    main_html = load_main_html()
    main_html = inject_fleet_status(main_html, fleet)
    document = wrap_pdf_document(
        main_html,
        fleet.get("generatedAtDisplay") or fleet.get("generatedAtUtc") or "Unknown",
    )

    try:
        from xhtml2pdf import pisa
    except ImportError as exc:
        raise RuntimeError("Install xhtml2pdf: pip3 install xhtml2pdf") from exc

    with OUTPUT.open("wb") as pdf_file:
        status = pisa.CreatePDF(document, dest=pdf_file, encoding="utf-8")
    if status.err:
        raise RuntimeError(f"PDF generation failed with {status.err} error(s)")

    return OUTPUT


def main() -> int:
    pdf_path = export_pdf()
    print(f"Created {pdf_path}")
    print(f"Download: http://10.90.105.221:8080/{pdf_path.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
