"""
Build the IDOS Staking-Aware Vesting audit PDF.

Pipeline:
  AUDIT.md  ──pandoc──▶  body.html (fragment)
  cover.html + body.html + style.css  ──compose──▶  report.html
  report.html  ──chrome --headless --print-to-pdf──▶  IDOSStakingVesting_Audit_v2.pdf

The wrapper adds severity badges (rewriting "Critical/High/Medium/Low/
Informational/Operational" tokens inside the master findings table and
the front-matter table) and status colouring (Fixed/Open/Acknowledged/
Recommended).
"""

from pathlib import Path
import subprocess
import re

ROOT = Path(__file__).resolve().parent.parent
TEMPLATE_DIR = ROOT / "audit_template"
MD_INPUT     = ROOT / "AUDIT.md"
HTML_FRAGMENT = TEMPLATE_DIR / "body.html"
COVER_FRAGMENT = TEMPLATE_DIR / "cover.html"
STYLE_CSS     = TEMPLATE_DIR / "style.css"
HTML_FULL     = TEMPLATE_DIR / "report.html"
PDF_OUT       = ROOT / "IDOSStakingVesting_Audit_v2.pdf"

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# 1) markdown → html fragment
subprocess.check_call([
    "pandoc", str(MD_INPUT),
    "--from=gfm+pipe_tables+task_lists",
    "--to=html5",
    "--no-highlight",
    "--standalone=false",
    "-o", str(HTML_FRAGMENT),
])

body = HTML_FRAGMENT.read_text()

# 2) Severity badge rewrites — only in cells of tables (not body prose).
SEV_MAP = {
    "Critical":      "sev-critical",
    "High":          "sev-high",
    "Medium":        "sev-medium",
    "Low":           "sev-low",
    "Informational": "sev-info",
    "Operational":   "sev-operational",
    "Methodology":   "sev-info",
}
STATUS_MAP = {
    "Fixed":        "status-fixed",
    "Resolved":     "status-fixed",
    "Open":         "status-open",
    "Acknowledged": "status-acknowledged",
    "Recommended":  "status-recommended",
}

def style_cells(html: str) -> str:
    """Inject .sev / .status classes into <td> cells matching known tokens."""
    def repl_cell(m: re.Match) -> str:
        inner = m.group(1)
        text = re.sub(r'<[^>]+>', '', inner).strip()
        # Severity bare tokens
        if text in SEV_MAP:
            return f'<td><span class="sev {SEV_MAP[text]}">{text}</span></td>'
        # Status with optional "Fixed in commit <hash>"
        for token, klass in STATUS_MAP.items():
            if text.startswith(token):
                return f'<td><span class="{klass}">{inner}</span></td>'
        return m.group(0)
    return re.sub(r'<td>(.*?)</td>', repl_cell, html, flags=re.DOTALL)

body = style_cells(body)

# 3) Highlight the COI disclosure block and §13.x callouts as .disclaimer
body = body.replace(
    "<blockquote>",
    '<blockquote class="disclaimer">'
)

# 4) Compose final HTML
cover = COVER_FRAGMENT.read_text()
html = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>IDOS Staking-Aware Vesting — Security Audit Report</title>
  <style>{STYLE_CSS.read_text()}</style>
</head>
<body>
{cover}
<main>
{body}
</main>
</body>
</html>"""
HTML_FULL.write_text(html)
print(f"composed {HTML_FULL}  ({len(html):,} chars)")

# 5) HTML → PDF via Chrome headless
subprocess.check_call([
    CHROME,
    "--headless=new",
    "--disable-gpu",
    "--no-sandbox",
    "--print-to-pdf-no-header",
    f"--print-to-pdf={PDF_OUT}",
    f"file://{HTML_FULL}",
])
print(f"wrote {PDF_OUT}  ({PDF_OUT.stat().st_size / 1024:.1f} KB)")
