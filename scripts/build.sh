#!/bin/zsh
# Builds "Quick Capture.app" and a drag-to-Applications DMG in ./dist.
#
#   scripts/build.sh                 # sign with your best available identity
#   scripts/build.sh --install       # also copy into /Applications and launch it
#
# Optional environment:
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"   pick a specific certificate
#   NOTARY_PROFILE=quickcapture     notarize + staple (create once with:
#       xcrun notarytool store-credentials quickcapture --apple-id you@example.com --team-id TEAMID)
#   UNIVERSAL=1                      build for Apple Silicon + Intel
#   BUNDLE_ID=com.you.QuickCapture   your own bundle identifier (keep it stable: macOS ties
#                                    the Screen Recording permission to it)
set -euo pipefail

ROOT="${0:A:h:h}"
NAME="Quick Capture"
BUNDLE_ID="${BUNDLE_ID:-com.xiaofanlu.ObsidianQuickCapture}"
VERSION="3.0.1"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
DIST="$ROOT/dist"
APP="$DIST/$NAME.app"
cd "$ROOT"

echo "▸ Compiling"
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/QuickCapture"
else
  swift build -c release
  BIN="$(swift build -c release --show-bin-path)/QuickCapture"
fi

echo "▸ Assembling $NAME.app"
rm -rf "$APP" "$DIST/Obsidian Quick Capture.app" "$DIST/Obsidian Quick Capture.dmg"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/QuickCapture"
# Each plugin's files live in Resources/<plugin id>/.
cp -R Resources/. "$APP/Contents/Resources/"

ICONSET="$(mktemp -d "${TMPDIR:-/tmp}/quickcapture-icon.XXXXXX")/AppIcon.iconset"
if [[ ! -f "$DIST/AppIcon.icns" || scripts/make_icon.swift -nt "$DIST/AppIcon.icns" ]]; then
  rm -rf "$ICONSET"
  swift scripts/make_icon.swift "$ICONSET"
  iconutil -c icns "$ICONSET" -o "$DIST/AppIcon.icns"
  rm -rf "$ICONSET"
fi
cp "$DIST/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>QuickCapture</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCameraUsageDescription</key><string>Nose Control reads the camera on this Mac to follow where your nose points. Video never leaves your Mac.</string>
  <key>NSHumanReadableCopyright</key><string>Shortcut-driven capture and AI chat for macOS.</string>
</dict>
</plist>
PLIST

echo "▸ Signing"
IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning | grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"' || true)"
fi
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning | grep -o '"Apple Development[^"]*"' | head -1 | tr -d '"' || true)"
fi
if [[ -z "$IDENTITY" ]]; then
  echo "  (no signing certificate found: ad-hoc signing — permissions may reset on every rebuild)"
  IDENTITY="-"
fi
echo "  identity: $IDENTITY"
SIGN_ARGS=(--force --options runtime --entitlements "$ROOT/scripts/entitlements.plist" --sign "$IDENTITY")
[[ "$IDENTITY" == Developer\ ID* ]] && SIGN_ARGS+=(--timestamp)
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict "$APP"

echo "▸ Creating DMG"
DMG="$DIST/$NAME.dmg"
# Stage outside the project. The DMG needs an "Applications" symlink, and a symlink to
# /Applications inside a synced or indexed folder (e.g. an Obsidian vault, which follows
# symlinks) makes that app try to index every file in /Applications and freeze.
# See docs/troubleshooting.md.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/quickcapture-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
rm -f "$DMG"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
rm -rf "$STAGE"
[[ "$IDENTITY" != "-" ]] && codesign --force --sign "$IDENTITY" "$DMG"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  if [[ "$IDENTITY" != Developer\ ID* ]]; then
    echo "  NOTARY_PROFILE set, but notarization requires a “Developer ID Application” certificate." >&2
    exit 1
  fi
  echo "▸ Notarizing (this can take a few minutes)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler staple "$APP"
fi

echo "✓ $APP"
echo "✓ $DMG"

if [[ "${1:-}" == "--install" ]]; then
  echo "▸ Installing to /Applications"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
  pkill -x QuickCapture 2>/dev/null || true
  sleep 0.5
  rm -rf "/Applications/$NAME.app" "/Applications/Obsidian Quick Capture.app"   # the app's name before 3.1
  cp -R "$APP" /Applications/
  open "/Applications/$NAME.app"
  echo "✓ Installed and launched /Applications/$NAME.app"
fi
