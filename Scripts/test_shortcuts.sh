#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/macshot-shortcuts.XXXXXX)"
trap '/bin/rm -R "$TEST_DIR"' EXIT

# A separate executable/domain keeps tests away from the installed app's preferences.
xcrun swiftc -swift-version 5 -module-name MacShotShortcutTests \
    "$ROOT_DIR/macshot/Services/HotkeyManager.swift" \
    "$ROOT_DIR/macshot/Services/FactorySettings.swift" \
    "$ROOT_DIR/macshot/Services/KeyboardShortcutMatcher.swift" \
    "$ROOT_DIR/macshot/Services/EditorCommandShortcutManager.swift" \
    "$ROOT_DIR/macshot/Services/SettingsPortability.swift" \
    "$ROOT_DIR/macshot/Services/CaptureExclusionStore.swift" \
    "$ROOT_DIR/Tests/Shortcuts/main.swift" \
    -o "$TEST_DIR/MacShotShortcutTests"
"$TEST_DIR/MacShotShortcutTests"
