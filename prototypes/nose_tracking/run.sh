#!/bin/bash
# Build and run the eye-tracking demo. Usage: ./run.sh [--no-mouse]
set -e
cd "$(dirname "$0")"
OUT="$(mktemp -d)/nosetrack"
swiftc -O nosetrack.swift -o "$OUT" -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
exec "$OUT" "$@"
