#!/bin/bash
# Build LaunchInspector.app from source and package it into a drag-to-install .dmg.
# Used both locally and by .github/workflows/release.yml.
#
#   scripts/make-dmg.sh [version]   # version defaults to "dev" (CI passes the tag, e.g. 0.2.0)
#
# Output: dist/LaunchInspector-<version>.dmg
#
# Signing: ad-hoc by default (no Apple Developer ID). A downloaded ad-hoc app
# triggers Gatekeeper once — users right-click → Open the first time. To ship a
# notarized build, set CODESIGN_IDENTITY to a "Developer ID Application" identity
# and add a notarize/staple step (see the workflow).
set -euo pipefail

APP_NAME="LaunchInspector"
VERSION="${1:-dev}"
# Keep the SwiftPM build cache out of Google Drive (a synced .build/ causes
# build.db disk-I/O errors and stale binaries). Harmless on CI runners too.
BUILD_DIR="${BUILD_DIR:-/tmp/li-release}"
DIST="${DIST:-dist}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}" # "-" = ad-hoc

cd "$(dirname "$0")/.."

echo "==> Compiling ($APP_NAME $VERSION)"
swift build -c release --scratch-path "$BUILD_DIR"
BIN="$BUILD_DIR/release/$APP_NAME"

echo "==> Assembling $APP_NAME.app"
STAGE_ROOT="$(mktemp -d)"
APP="$STAGE_ROOT/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>com.vincentbattez.launch-inspector</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 Vincent Battez. MIT License.</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> Signing ($CODESIGN_IDENTITY)"
# Hardened runtime is required for notarization (Developer ID) but can hinder an
# ad-hoc build, so only enable it for a real identity.
if [ "$CODESIGN_IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP"
fi

echo "==> Packaging .dmg"
mkdir -p "$DIST"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
rm -f "$DMG"
ln -s /Applications "$STAGE_ROOT/Applications" # drag-to-install target
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE_ROOT" -ov -format UDZO "$DMG" >/dev/null

echo "==> Done: $DMG"
