#!/bin/zsh
set -e
ROOT="${0:A:h}"
RUNTIME="$HOME/Library/Application Support/Obsidian Quick Capture/venv"
if [[ ! -x "$RUNTIME/bin/python" ]]; then
  python3 -m venv "$RUNTIME"
  "$RUNTIME/bin/python" -m pip install -r "$ROOT/requirements.txt"
fi
exec "$RUNTIME/bin/python" "$ROOT/quick_capture.py"
