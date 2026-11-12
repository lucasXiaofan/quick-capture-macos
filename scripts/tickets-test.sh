#!/bin/zsh
# Checks the Tickets plugin's Markdown file format (write a ticket, read it back) and its page logic.
set -euo pipefail
ROOT="${0:A:h:h}"
S="$ROOT/Sources/QuickCapture/Plugins/Tickets"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -o "$TMP/tickets_format" "$ROOT/tests/tickets_format/main.swift" "$S/TicketModel.swift" "$S/TicketMarkdown.swift"
"$TMP/tickets_format"
swiftc -o "$TMP/tickets_git" "$ROOT/tests/tickets_git/main.swift" "$S/TicketGit.swift" "$ROOT/Sources/QuickCapture/Core/Shell.swift"
"$TMP/tickets_git"
node "$ROOT/tests/tickets.test.cjs"

swiftc -o "$TMP/tickets_workspace" "$ROOT/tests/tickets_workspace/main.swift" "$S/TicketModel.swift" "$S/TicketMarkdown.swift" "$S/TicketWorkspaceImport.swift" "$S/TicketStore.swift" "$S/TicketTags.swift"
"$TMP/tickets_workspace" "$@"

swiftc -o "$TMP/tickets_tools" "$ROOT/tests/tickets_tools/main.swift" "$S/TicketModel.swift" "$S/TicketMarkdown.swift" "$S/TicketWorkspaceImport.swift" "$S/TicketStore.swift" "$S/TicketTags.swift" "$S/TicketTools.swift"
"$TMP/tickets_tools"

node "$ROOT/tests/tickets_project_render.test.cjs"

node "$ROOT/tests/tickets_dispatch.test.cjs"
