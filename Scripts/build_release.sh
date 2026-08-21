#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${MACSHOT_RELEASE_DERIVED_DATA:-$ROOT_DIR/.release/DerivedData}"
BUILD_DIR="$ROOT_DIR/Build"
APP_PATH="$BUILD_DIR/macshot.app"
ZIP_PATH="$BUILD_DIR/MacShot.zip"
NOTARY_RESULT_PATH="$BUILD_DIR/notary-result.json"

RELEASE_VERSION="${RELEASE_VERSION:-4.2.2}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
NOTARY_PROFILE="${MACSHOT_NOTARY_PROFILE:-${NOTARY_PROFILE:-}}"
NOTARY_KEYCHAIN="${MACSHOT_NOTARY_KEYCHAIN:-${NOTARY_KEYCHAIN:-}}"
SIGNING_KEYCHAIN="${MACSHOT_SIGNING_KEYCHAIN:-${SIGNING_KEYCHAIN:-}}"
KEYCHAIN_PASSWORD_FILE="${MACSHOT_KEYCHAIN_PASSWORD_FILE:-${KEYCHAIN_PASSWORD_FILE:-}}"
CODESIGN_VIA_LAUNCHCTL="${CODESIGN_VIA_LAUNCHCTL:-0}"
NOTARY_VIA_LAUNCHCTL="${NOTARY_VIA_LAUNCHCTL:-0}"

if [[ ! "$RELEASE_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    echo "RELEASE_VERSION must contain two or three numeric components." >&2
    exit 1
fi
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "BUILD_NUMBER must contain digits only." >&2
    exit 1
fi
if [[ -z "$NOTARY_PROFILE" ]]; then
    echo "A local notarytool Keychain profile is required." >&2
    echo "Set MACSHOT_NOTARY_PROFILE only in the release runner environment." >&2
    exit 1
fi

for forbidden in APPLE_ID APPLE_PASSWORD APP_SPECIFIC_PASSWORD ASC_PROVIDER ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_FILE; do
    if [[ -n "${!forbidden:-}" ]]; then
        echo "Direct notarization credentials are not accepted. Use a local Keychain profile." >&2
        exit 1
    fi
done

run_codesign() {
    if [[ "$CODESIGN_VIA_LAUNCHCTL" == "1" ]]; then
        launchctl asuser "$(id -u)" codesign "$@"
    else
        codesign "$@"
    fi
}

run_notarytool() {
    if [[ "$NOTARY_VIA_LAUNCHCTL" == "1" ]]; then
        launchctl asuser "$(id -u)" xcrun notarytool "$@"
    else
        xcrun notarytool "$@"
    fi
}

NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
if [[ -n "$NOTARY_KEYCHAIN" ]]; then
    [[ -f "$NOTARY_KEYCHAIN" && ! -L "$NOTARY_KEYCHAIN" ]] || {
        echo "The configured notarization Keychain is unavailable or unsafe." >&2
        exit 1
    }
    NOTARY_ARGS+=(--keychain "$NOTARY_KEYCHAIN")
fi

if [[ -n "$KEYCHAIN_PASSWORD_FILE" ]]; then
    [[ -f "$KEYCHAIN_PASSWORD_FILE" && ! -L "$KEYCHAIN_PASSWORD_FILE" ]] || {
        echo "The local Keychain password file is unavailable or unsafe." >&2
        exit 1
    }
    keychain_password="$(<"$KEYCHAIN_PASSWORD_FILE")"
    [[ -n "$keychain_password" ]] || {
        echo "The local Keychain password file is empty." >&2
        exit 1
    }
    keychain_to_unlock="${SIGNING_KEYCHAIN:-${NOTARY_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}}"
    security unlock-keychain -p "$keychain_password" "$keychain_to_unlock"
    unset keychain_password
fi

if ! run_notarytool history "${NOTARY_ARGS[@]}" >/dev/null 2>&1; then
    echo "The local notarytool Keychain profile is unavailable or invalid." >&2
    exit 1
fi

identity_search_args=(-v -p codesigning)
if [[ -n "$SIGNING_KEYCHAIN" ]]; then
    [[ -f "$SIGNING_KEYCHAIN" && ! -L "$SIGNING_KEYCHAIN" ]] || {
        echo "The configured signing Keychain is unavailable or unsafe." >&2
        exit 1
    }
    identity_search_args+=("$SIGNING_KEYCHAIN")
fi
SIGNING_IDENTITY="$(security find-identity "${identity_search_args[@]}" | awk '/Developer ID Application:/ { print $2; exit }')"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    echo "No Developer ID Application signing identity is available." >&2
    exit 1
fi

for target in "$DERIVED_DATA" "$BUILD_DIR"; do
    if [[ "$target" != "$ROOT_DIR"/.release/* && "$target" != "$ROOT_DIR/Build" ]]; then
        echo "Refusing to reset an unexpected release path." >&2
        exit 1
    fi
    /bin/rm -R "$target" 2>/dev/null || true
done
mkdir -p "$DERIVED_DATA" "$BUILD_DIR"
touch "$ROOT_DIR/.release/.metadata_never_index" "$BUILD_DIR/.metadata_never_index"

cleanup_registration() {
    for generated_app in \
        "$DERIVED_DATA/Build/Products/Release/macshot.app" \
        "$APP_PATH"; do
        if [[ -d "$generated_app" ]]; then
            /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
                -u "$generated_app" >/dev/null 2>&1 || true
        fi
    done
}
trap cleanup_registration EXIT

echo "Building the public MacShot fork for Apple Silicon and Intel."
xcodebuild -quiet \
    -project "$ROOT_DIR/macshot.xcodeproj" \
    -scheme macshot \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    -destination 'generic/platform=macOS' \
    ARCHS='arm64 x86_64' \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    MARKETING_VERSION="$RELEASE_VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    PRODUCT_BUNDLE_IDENTIFIER='com.itvx.macshot' \
    build

PRODUCT_APP="$DERIVED_DATA/Build/Products/Release/macshot.app"
[[ -d "$PRODUCT_APP" ]] || {
    echo "The release app was not produced." >&2
    exit 1
}
ditto "$PRODUCT_APP" "$APP_PATH"

PLIST="$APP_PATH/Contents/Info.plist"
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$PLIST")" == "com.itvx.macshot" ]] || {
    echo "Release bundle identifier is incorrect." >&2
    exit 1
}
[[ "$(plutil -extract SUFeedURL raw -o - "$PLIST")" == "https://github.com/iTvX/macshot/releases/download/appcast/appcast.xml" ]] || {
    echo "Release update feed is incorrect." >&2
    exit 1
}
[[ "$(plutil -extract SUPublicEDKey raw -o - "$PLIST")" == "IhqEpsOY8hgaC0YtEMKssi2d571eLCblCanpUD5t50g=" ]] || {
    echo "Release Sparkle public key is incorrect." >&2
    exit 1
}

SPARKLE="$APP_PATH/Contents/Frameworks/Sparkle.framework"
for nested in \
    "$SPARKLE/Versions/Current/XPCServices/Downloader.xpc" \
    "$SPARKLE/Versions/Current/XPCServices/Installer.xpc" \
    "$SPARKLE/Versions/Current/Updater.app" \
    "$SPARKLE/Versions/Current/Autoupdate"; do
    if [[ -e "$nested" ]]; then
        run_codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$nested"
    fi
done
run_codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$SPARKLE"
run_codesign --force --options runtime --timestamp \
    --entitlements "$ROOT_DIR/macshot/macshot.entitlements" \
    --sign "$SIGNING_IDENTITY" "$APP_PATH"

run_codesign --verify --deep --strict "$APP_PATH"
if run_codesign -d --entitlements :- "$APP_PATH" 2>/dev/null | grep -q 'get-task-allow'; then
    echo "The release app unexpectedly contains get-task-allow." >&2
    exit 1
fi
for architecture in arm64 x86_64; do
    lipo "$APP_PATH/Contents/MacOS/macshot" -verify_arch "$architecture" >/dev/null
done

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
echo "Submitting the signed archive to Apple notarization."
if ! run_notarytool submit "$ZIP_PATH" "${NOTARY_ARGS[@]}" \
    --wait --output-format json > "$NOTARY_RESULT_PATH"; then
    echo "Apple notarization submission failed." >&2
    exit 1
fi
if [[ "$(plutil -extract status raw -o - "$NOTARY_RESULT_PATH" 2>/dev/null || true)" != "Accepted" ]]; then
    echo "Apple did not accept the notarization submission." >&2
    exit 1
fi

xcrun stapler staple "$APP_PATH" >/dev/null
xcrun stapler validate "$APP_PATH" >/dev/null
spctl --assess --type execute "$APP_PATH"

/bin/rm "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
shasum -a 256 "$ZIP_PATH" | awk '{print $1}' > "$ZIP_PATH.sha256"

echo "Release archive is signed, notarized, stapled, and ready."
