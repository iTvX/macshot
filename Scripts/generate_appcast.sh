#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_TAG="${RELEASE_TAG:?Set RELEASE_TAG to the GitHub release tag.}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required.}"
SPARKLE_ACCOUNT="${MACSHOT_SPARKLE_ACCOUNT:-app.macshot.capture.sparkle}"
SPARKLE_BIN_DIR="${MACSHOT_SPARKLE_BIN_DIR:-$ROOT_DIR/.release/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin}"
ARCHIVES_DIR="$ROOT_DIR/Build/Appcast"
APPCAST_PATH="$ARCHIVES_DIR/appcast.xml"

[[ -x "$SPARKLE_BIN_DIR/generate_appcast" ]] || {
    echo "Sparkle generate_appcast is unavailable in the local build artifacts." >&2
    exit 1
}
[[ -f "$ROOT_DIR/Build/MacShot.zip" ]] || {
    echo "Build/MacShot.zip is missing." >&2
    exit 1
}

/bin/rm -R "$ARCHIVES_DIR" 2>/dev/null || true
mkdir -p "$ARCHIVES_DIR"
cp "$ROOT_DIR/Build/MacShot.zip" "$ARCHIVES_DIR/MacShot.zip"

existing_url="https://github.com/$GITHUB_REPOSITORY/releases/download/appcast/appcast.xml"
curl -fsSL "$existing_url" -o "$APPCAST_PATH" 2>/dev/null || true

"$SPARKLE_BIN_DIR/generate_appcast" \
    --account "$SPARKLE_ACCOUNT" \
    --download-url-prefix "https://github.com/$GITHUB_REPOSITORY/releases/download/$RELEASE_TAG/" \
    --link "https://github.com/$GITHUB_REPOSITORY" \
    --maximum-versions 3 \
    "$ARCHIVES_DIR" >/dev/null

[[ -s "$APPCAST_PATH" ]] || {
    echo "Sparkle did not generate an appcast." >&2
    exit 1
}
grep -Fq "releases/download/$RELEASE_TAG/MacShot.zip" "$APPCAST_PATH" || {
    echo "The appcast does not point to the current release archive." >&2
    exit 1
}

echo "Sparkle appcast generated and signed."
