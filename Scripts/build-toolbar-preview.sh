#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
preview_dir="${MACSHOT_TOOLBAR_PREVIEW_DIR:-$(mktemp -d /tmp/macshot-toolbar-preview.XXXXXX)}"
mkdir -p "$preview_dir"
ditto macshot "$preview_dir/macshot"
ditto macshot.xcodeproj "$preview_dir/macshot.xcodeproj"
cp Scripts/preview-toolbar.swift "$preview_dir/macshot/main.swift"
xcodebuild -quiet -project "$preview_dir/macshot.xcodeproj" -scheme macshot -configuration Debug \
  -derivedDataPath "$preview_dir/build" -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  PRODUCT_BUNDLE_IDENTIFIER=com.itvx.macshot.toolbar-preview build > "$preview_dir/build.log" 2>&1
printf '%s\n' "$preview_dir/build/Build/Products/Debug/macshot.app"
