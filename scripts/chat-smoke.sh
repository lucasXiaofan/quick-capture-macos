#!/bin/zsh
# Runs a real two-turn conversation through the AI Chat engine (uses your CLI sign-in and a
# little of your quota). Runs with a minimal environment, like an app opened from Finder.
#   scripts/chat-smoke.sh claude sonnet
#   scripts/chat-smoke.sh codex gpt-6-luna
set -euo pipefail
ROOT="${0:A:h:h}"
S="$ROOT/Sources/QuickCapture"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -o "$TMP/chat_smoke" "$ROOT/tests/chat_smoke/main.swift" \
  "$S/Plugins/AIChat/AgentBackends.swift" "$S/Plugins/AIChat/ChatSession.swift" "$S/Core/Shell.swift"
mkdir "$TMP/work"
env -i HOME="$HOME" USER="$USER" SHELL="${SHELL:-/bin/zsh}" PATH=/usr/bin:/bin "$TMP/chat_smoke" "${1:-claude}" "${2:-sonnet}" "$TMP/work"
