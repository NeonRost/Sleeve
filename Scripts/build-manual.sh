#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds docs/Sleeve-Manual.pdf from manual/source.html, as for TOM: the
# page is printed to A4 by Chrome without a window. Chrome also writes the
# headings as PDF bookmarks; their pages fill in the contents, then the page
# is printed a second time.
#
#   Scripts/build-manual.sh
#
# Needs Google Chrome in /Applications. Nothing is installed.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/manual/source.html"
OUT="$ROOT/docs/Sleeve-Manual.pdf"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -x "$CHROME" ] || { echo "Google Chrome not found in /Applications" >&2; exit 1; }

print_pdf() {
  # Headless Chrome occasionally does not exit after printing — give it a
  # minute, then end it; the PDF is complete by then.
  "$CHROME" --headless=new --disable-gpu --no-first-run --user-data-dir="$WORK/profile" \
    --no-pdf-header-footer --generate-pdf-document-outline \
    --print-to-pdf="$1" "file://$SRC" >/dev/null 2>&1 &
  local pid=$!
  for _ in $(seq 1 60); do
    kill -0 $pid 2>/dev/null || break
    [ -s "$1" ] && sleep 2 && break
    sleep 1
  done
  kill $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true
  [ -s "$1" ] || { echo "Chrome produced no PDF" >&2; exit 1; }
}

# 1. First pass, to learn where the chapters start.
print_pdf "$WORK/pass1.pdf"

# 2. Page of every chapter heading from the bookmarks ("1What Sleeve does" …).
cat > "$WORK/pages.swift" <<'SWIFT'
import PDFKit
let doc = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1]))!
func walk(_ item: PDFOutline) {
    for i in 0..<item.numberOfChildren {
        let child = item.child(at: i)!
        if let label = child.label, let page = child.destination?.page {
            let digits = label.prefix { $0.isNumber }
            if !digits.isEmpty { print("\(digits) \(doc.index(for: page) + 1)") }
        }
        walk(child)
    }
}
walk(doc.outlineRoot!)
SWIFT
swift "$WORK/pages.swift" "$WORK/pass1.pdf" > "$WORK/pages.txt"

# 3. Write them into the contents of the source.
python3 - "$SRC" "$WORK/pages.txt" <<'PY'
import re, sys
src, pages = sys.argv[1], dict(line.split() for line in open(sys.argv[2]))
html = open(src, encoding="utf-8").read()
def fill(m):
    return m.group(1) + pages.get(m.group(2), m.group(3)) + m.group(4)
new = re.sub(r'(<span class="toc-page" data-toc="(\d+)">)(\d+)(</span>)', fill, html)
open(src, "w", encoding="utf-8").write(new)
print("contents:", " ".join(f"{k}→{v}" for k, v in sorted(pages.items(), key=lambda kv: int(kv[0]))))
PY

# 4. Final pass.
print_pdf "$WORK/final.pdf"
mv "$WORK/final.pdf" "$OUT"
echo "Written: docs/Sleeve-Manual.pdf ($(du -h "$OUT" | cut -f1 | tr -d ' '))"
