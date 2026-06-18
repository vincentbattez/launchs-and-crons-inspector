#!/bin/bash
# Generate the Sparkle appcast.xml for a release (single latest item).
#
#   scripts/make-appcast.sh <version> <dmg-path> <enclosure-url> [out=appcast.xml]
#
# The EdDSA signature comes from $SPARKLE_PRIVATE_KEY (stdin) when set — the CI
# path — otherwise from the macOS Keychain (local path). Sparkle tools are looked
# up in $SPARKLE_BIN (default /tmp/sparkle/bin).
set -euo pipefail

VERSION="$1"
DMG="$2"
URL="$3"
OUT="${4:-appcast.xml}"
SPARKLE_BIN="${SPARKLE_BIN:-/tmp/sparkle/bin}"
MIN_OS="14.0"

if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  SIG="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SPARKLE_BIN/sign_update" --ed-key-file - -p "$DMG")"
else
  SIG="$("$SPARKLE_BIN/sign_update" -p "$DMG")"
fi
LEN="$(stat -f%z "$DMG")"

cat > "$OUT" <<XML
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>LaunchInspector</title>
    <item>
      <title>$VERSION</title>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <enclosure url="$URL" sparkle:edSignature="$SIG" length="$LEN" type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML

echo "Wrote $OUT (v$VERSION, len=$LEN)"
