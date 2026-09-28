#!/bin/zsh
# Refreshes the web libraries bundled with the AI Chat page (Resources/ai_chat/vendor).
# They are committed, so building the app never needs the network; run this only to upgrade.
#
#   scripts/vendor.sh                    # pinned versions below
#   MARKED=18 KATEX=0.18 scripts/vendor.sh
set -euo pipefail

ROOT="${0:A:h:h}"
DEST="$ROOT/Resources/ai_chat/vendor"
MARKED="${MARKED:-18.0.14}"
KATEX="${KATEX:-0.18.9}"
DOMPURIFY="${DOMPURIFY:-3.4.16}"
HLJS="${HLJS:-11.12.0}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
npm pack --silent "marked@$MARKED" "katex@$KATEX" "dompurify@$DOMPURIFY" "@highlightjs/cdn-assets@$HLJS" >/dev/null
for f in *.tgz; do mkdir -p "${f%.tgz}"; tar xzf "$f" -C "${f%.tgz}"; done

mkdir -p "$DEST/katex/fonts"
cp marked-*/package/lib/marked.umd.js "$DEST/marked.umd.js"
cp dompurify-*/package/dist/purify.min.js "$DEST/"
cp highlightjs-cdn-assets-*/package/highlight.min.js "$DEST/"
cp highlightjs-cdn-assets-*/package/styles/github.min.css "$DEST/hljs-light.min.css"
cp highlightjs-cdn-assets-*/package/styles/github-dark.min.css "$DEST/hljs-dark.min.css"
cp katex-*/package/dist/katex.min.js katex-*/package/dist/katex.min.css "$DEST/katex/"
rm -f "$DEST"/katex/fonts/*
cp katex-*/package/dist/fonts/*.woff2 "$DEST/katex/fonts/"

{
  for d in */package; do
    echo "==== $(node -p "const p=require('./$d/package.json'); p.name+'@'+p.version") ===="
    cat "$d"/LICENSE* 2>/dev/null || true
    echo
  done
} > "$DEST/LICENSES.txt"

echo "✓ Updated $DEST"
node "$ROOT/tests/render.test.cjs"
