#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${MACSHOT_TEST_DERIVED_DATA:-$ROOT_DIR/.release/TestDerivedData}"

if [[ "$DERIVED_DATA" != "$ROOT_DIR"/.release/* ]]; then
    echo "Test DerivedData must stay under the repository .release directory." >&2
    exit 1
fi

/bin/rm -R "$DERIVED_DATA" 2>/dev/null || true
mkdir -p "$DERIVED_DATA"
touch "$ROOT_DIR/.release/.metadata_never_index"

cleanup() {
    local generated_app="$DERIVED_DATA/Build/Products/Debug/macshot.app"
    if [[ -d "$generated_app" ]]; then
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
            -u "$generated_app" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

xcodebuild -quiet \
    -project "$ROOT_DIR/macshot.xcodeproj" \
    -scheme macshot \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build

echo "Debug build validation passed."
