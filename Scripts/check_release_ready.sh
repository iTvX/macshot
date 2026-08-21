#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$ROOT_DIR/Build/macshot.app"
ZIP_PATH="$ROOT_DIR/Build/MacShot.zip"

[[ -d "$APP_PATH" && -f "$ZIP_PATH" && -f "$ZIP_PATH.sha256" ]] || {
    echo "Release artifacts are incomplete." >&2
    exit 1
}

codesign --verify --deep --strict "$APP_PATH"
xcrun stapler validate "$APP_PATH" >/dev/null
spctl --assess --type execute "$APP_PATH"

[[ "$(plutil -extract CFBundleIdentifier raw -o - "$APP_PATH/Contents/Info.plist")" == "com.itvx.macshot" ]]
[[ "$(plutil -extract SUFeedURL raw -o - "$APP_PATH/Contents/Info.plist")" == "https://github.com/iTvX/macshot/releases/download/appcast/appcast.xml" ]]
[[ "$(plutil -extract SUPublicEDKey raw -o - "$APP_PATH/Contents/Info.plist")" == "IhqEpsOY8hgaC0YtEMKssi2d571eLCblCanpUD5t50g=" ]]

for architecture in arm64 x86_64; do
    lipo "$APP_PATH/Contents/MacOS/macshot" -verify_arch "$architecture" >/dev/null
done

verify_dir="$(mktemp -d /tmp/macshot-release-check.XXXXXX)"
trap '/bin/rm -R "$verify_dir"' EXIT
ditto -x -k "$ZIP_PATH" "$verify_dir"
codesign --verify --deep --strict "$verify_dir/macshot.app"
xcrun stapler validate "$verify_dir/macshot.app" >/dev/null

expected_hash="$(<"$ZIP_PATH.sha256")"
actual_hash="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
[[ "$expected_hash" == "$actual_hash" ]] || {
    echo "Release checksum does not match." >&2
    exit 1
}

echo "Release readiness checks passed."
