#!/bin/bash
# Build LaunchInspector.app (Xcode target, Sparkle embedded) and package it into
# a drag-to-install .dmg. Used both locally and by .github/workflows/release.yml.
#
#   scripts/make-dmg.sh [version]   # version defaults to "dev" (CI passes the tag, e.g. 0.3.0)
#
# Output: dist/LaunchInspector-<version>.dmg
#
# The app is ad-hoc signed by Xcode (no Apple Developer ID). A downloaded build
# triggers Gatekeeper once — users right-click → Open the first time.
set -euo pipefail

APP_NAME="LaunchInspector"
VERSION="${1:-dev}"
DERIVED="${DERIVED:-/tmp/li-xcode}"
DIST="${DIST:-dist}"

cd "$(dirname "$0")/.."

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Building $APP_NAME $VERSION (Release)"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
  -derivedDataPath "$DERIVED" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$VERSION" \
  build
APP="$DERIVED/Build/Products/Release/$APP_NAME.app"

echo "==> Packaging .dmg"
mkdir -p "$DIST"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications" # drag-to-install target
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "==> Done: $DMG"
