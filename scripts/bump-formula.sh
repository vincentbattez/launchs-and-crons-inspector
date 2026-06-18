#!/bin/bash
# Point a Homebrew formula at a new release tag: recompute the source-tarball
# sha256 and rewrite the `url` + `sha256` lines in place.
#
#   scripts/bump-formula.sh <version> <path/to/launch-inspector.rb>
#
# <version> has no leading "v" (e.g. 0.2.0). Run by the release workflow against
# a checkout of the tap repo; also usable by hand.
set -euo pipefail

VERSION="$1"
FORMULA="$2"
REPO="vincentbattez/launchs-and-crons-inspector"
URL="https://github.com/$REPO/archive/refs/tags/v$VERSION.tar.gz"

SHA="$(curl -fsSL "$URL" | shasum -a 256 | awk '{print $1}')"
[ -n "$SHA" ] || { echo "could not fetch tarball: $URL" >&2; exit 1; }

# Portable in-place edit (works with both BSD and GNU sed).
tmp="$(mktemp)"
sed -E \
  -e "s|^  url \".*\"|  url \"$URL\"|" \
  -e "s|^  sha256 \".*\"|  sha256 \"$SHA\"|" \
  "$FORMULA" > "$tmp"
mv "$tmp" "$FORMULA"

echo "Bumped $(basename "$FORMULA") -> v$VERSION ($SHA)"
