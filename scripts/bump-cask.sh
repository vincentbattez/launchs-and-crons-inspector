#!/bin/bash
# Point the Homebrew cask at a new release: rewrite the `version` and `sha256`
# (of the .dmg) lines in place.
#
#   scripts/bump-cask.sh <version> <dmg-sha256> <path/to/launch-inspector.rb>
#
# <version> has no leading "v". Run by the release workflow against a checkout of
# the tap repo; also usable by hand.
set -euo pipefail

VERSION="$1"
SHA="$2"
CASK="$3"

tmp="$(mktemp)"
sed -E \
  -e "s|^  version \".*\"|  version \"$VERSION\"|" \
  -e "s|^  sha256 \".*\"|  sha256 \"$SHA\"|" \
  "$CASK" > "$tmp"
mv "$tmp" "$CASK"

echo "Bumped $(basename "$CASK") -> $VERSION ($SHA)"
