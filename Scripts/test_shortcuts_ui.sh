#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${MACSHOT_TEST_DERIVED_DATA:-$ROOT_DIR/.release/TestDerivedData}"
PRODUCTS="$DERIVED_DATA/Build/Products/Debug"
TEST_DIR="$(mktemp -d /tmp/macshot-shortcuts-ui.XXXXXX)"
trap '/bin/rm -R "$TEST_DIR"' EXIT

# Link the actual Debug app so the tests exercise its real settings controls.
xcrun swiftc -swift-version 5 -default-isolation MainActor \
    -I "$PRODUCTS" -F "$PRODUCTS" \
    -Xcc "-fmodule-map-file=$DERIVED_DATA/Build/Intermediates.noindex/GeneratedModuleMaps/libwebp.modulemap" \
    "$PRODUCTS/macshot.app/Contents/MacOS/macshot.debug.dylib" \
    -Xlinker -rpath -Xlinker "$PRODUCTS/macshot.app/Contents/MacOS" \
    -Xlinker -rpath -Xlinker "$PRODUCTS" \
    "$ROOT_DIR/Tests/ShortcutsUI/main.swift" \
    -o "$TEST_DIR/MacShotShortcutUITests"
"$TEST_DIR/MacShotShortcutUITests"
