#!/usr/bin/env bash
# Re-render every .mmd in assets/mmd to SVG with the shared theme config.
#
# Guarantees:
#   - transparent canvas (no yellow cluster fill, no grey actor boxes) — every
#     figure sits cleanly on the GitHub README, the docs pages, the PDF, and
#     dark-mode surfaces
#   - one shared look: same node palette, fonts, and label treatment across
#     all figures (assets/mmd/config/mmd-config.json)
#
# Requires: mmdc (brew install mermaid-cli) and a Chrome/Chromium binary.
# The Chrome path differs per machine, so this script auto-detects one and
# writes a throwaway puppeteer config (never committed).

set -euo pipefail
cd "$(dirname "$0")/../.."   # repo root

MMD_DIR="assets/mmd"
OUT_DIR="$MMD_DIR"
CONFIG="$MMD_DIR/config/mmd-config.json"

# find a chrome binary: Chrome for Testing first (puppeteer-grade, no first-run
# state), then Google Chrome; plain Chromium.app hangs on headless launch here
CHROME=""
for c in \
    "$HOME/.hermes/tools"/chromium-*/chrome-mac-arm64/"Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing" \
    "/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing" \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    "/Applications/Chromium.app/Contents/MacOS/Chromium"; do
  [ -x "$c" ] && CHROME="$c" && break
done
[ -n "$CHROME" ] || { echo "error: no Chrome/Chromium found; install one or edit this script" >&2; exit 1; }

PPTR="$(mktemp /tmp/pptr.XXXXXX.json)"
cat > "$PPTR" <<EOF
{"executablePath": "$CHROME", "args": ["--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage"]}
EOF
trap 'rm -f "$PPTR"' EXIT

for f in "$MMD_DIR"/*.mmd; do
  name="$(basename "$f" .mmd)"
  echo "rendering $name"
  mmdc -i "$f" -o "$OUT_DIR/$name.svg" \
       -b transparent --scale 2 \
       -p "$PPTR" -c "$CONFIG"
done

# normalize sequence-diagram actor rects: the inline fill/stroke attrs are dead CSS-clobbered
# markup, but keep the committed SVG honest (attrs = rendered colors)
for svg in "$OUT_DIR"/*.svg; do
  python3 - "$svg" <<'PYEOF'
import sys, re
p = sys.argv[1]
t = open(p).read()
t2 = t.replace('fill="#eaeaea" stroke="#666"', 'fill="#e8eef7" stroke="#5b7db1"')
if not t2.endswith('\n'):   # keep pre-commit's end-of-file-fixer happy
    t2 += '\n'
if t2 != t:
    open(p, "w").write(t2)
    if 'fill="#eaeaea"' in t:
        print()  # actor fills + EOF newline normalized
PYEOF
done

echo "done: $(ls "$OUT_DIR"/*.svg | wc -l | tr -d ' ') svgs rendered from assets/mmd/*.mmd"
