#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
preview_dir="${MACSHOT_TOOLBAR_PREVIEW_DIR:-$(mktemp -d /tmp/macshot-toolbar-preview.XXXXXX)}"
mkdir -p "$preview_dir"
ditto macshot "$preview_dir/macshot"
ditto macshot.xcodeproj "$preview_dir/macshot.xcodeproj"
cp Scripts/preview-toolbar.swift "$preview_dir/macshot/main.swift"
# These services use an explicit data root rather than Bundle.main's identifier.
# Rewrite only the temporary copy so preview editor output cannot touch real history.
python3 - "$preview_dir/macshot/Services" <<'PYTHON'
import pathlib, sys
for name in ("ScreenshotHistory.swift", "ClipboardBackingStore.swift"):
    source = pathlib.Path(sys.argv[1]) / name
    source.write_text(source.read_text().replace("com.itvx.macshot", "com.itvx.macshot.toolbar-preview"))
PYTHON
xcodebuild -quiet -project "$preview_dir/macshot.xcodeproj" -scheme macshot -configuration Debug \
  -derivedDataPath "$preview_dir/build" -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  PRODUCT_BUNDLE_IDENTIFIER=com.itvx.macshot.toolbar-preview build > "$preview_dir/build.log" 2>&1
printf '%s\n' "$preview_dir/build/Build/Products/Debug/macshot.app"
