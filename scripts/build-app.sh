#!/bin/bash
set -euo pipefail
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(dirname -- "$SCRIPT_DIR")"
[[ -f "$PROJECT_ROOT/Package.swift" ]] || { printf '%s\n' "Package.swift not found." >&2; exit 1; }
ls -d "$PROJECT_ROOT" >/dev/null
plutil -lint "$PROJECT_ROOT/Resources/Info.plist" "$PROJECT_ROOT/Resources/WhisperType.entitlements"

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
swift build --package-path "$PROJECT_ROOT" --sdk "$SDK_PATH" --configuration release --product WhisperType
BIN_DIR="$(swift build --package-path "$PROJECT_ROOT" --sdk "$SDK_PATH" --configuration release --show-bin-path)"
[[ -x "$BIN_DIR/WhisperType" ]] || { printf '%s\n' "Release executable not found." >&2; exit 1; }

DIST="$PROJECT_ROOT/dist"
[[ ! -L "$DIST" ]] || { printf '%s\n' "Refusing a symlinked dist directory." >&2; exit 1; }
mkdir -p "$DIST"
ls -d "$DIST" >/dev/null
APP="$DIST/WhisperType.app"
# Build afresh in dist so failed compilation/signing leaves the previous bundle intact.
STAGING="$(mktemp -d "$DIST/.WhisperType.XXXXXX")"
trap 'rm -rf -- "$STAGING"' EXIT
BUNDLE="$STAGING/WhisperType.app"
ls -d "$STAGING" >/dev/null
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN_DIR/WhisperType" "$BUNDLE/Contents/MacOS/WhisperType"
chmod 755 "$BUNDLE/Contents/MacOS/WhisperType"
cp "$PROJECT_ROOT/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"
codesign --force --sign - --options runtime --timestamp=none \
    --entitlements "$PROJECT_ROOT/Resources/WhisperType.entitlements" "$BUNDLE"
codesign --verify --strict --verbose=2 "$BUNDLE"
[[ ! -L "$APP" ]] || { printf '%s\n' "Refusing a symlinked app bundle." >&2; exit 1; }
if [[ -e "$APP" ]]; then
    mv "$APP" "$STAGING/previous.app"
fi
if ! mv "$BUNDLE" "$APP"; then
    if [[ -d "$STAGING/previous.app" ]]; then mv "$STAGING/previous.app" "$APP"; fi
    exit 1
fi
printf 'Built %s\nAd-hoc signed for local use, not notarized. Nothing was installed or launched.\n' "$APP"
