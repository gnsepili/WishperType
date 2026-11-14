#!/bin/bash
set -euo pipefail
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(dirname -- "$SCRIPT_DIR")"
DIST="$PROJECT_ROOT/dist"
APP="$DIST/WhisperType.app"
[[ -d "$APP" && ! -L "$DIST" && ! -L "$APP" ]] || {
    printf '%s\n' "Build dist/WhisperType.app first with ./scripts/build-app.sh." >&2
    exit 1
}
codesign --verify --strict --verbose=2 "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$VERSION" =~ ^[0-9]+([.][0-9]+)*$ ]] || { printf '%s\n' "Invalid app version." >&2; exit 1; }
ARCHS="$(lipo -archs "$APP/Contents/MacOS/WhisperType")"
case "$ARCHS" in
    arm64|x86_64) ARCH="$ARCHS" ;;
    "arm64 x86_64"|"x86_64 arm64") ARCH="universal" ;;
    *) printf 'Unsupported architecture: %s\n' "$ARCHS" >&2; exit 1 ;;
esac
NAME="WhisperType-$VERSION-$ARCH.dmg"
OUTPUT="$DIST/$NAME"
[[ ! -L "$OUTPUT" && ! -d "$OUTPUT" ]] || { printf '%s\n' "Refusing an unsafe output path." >&2; exit 1; }
ls -d "$DIST" >/dev/null
STAGING="$(mktemp -d "$DIST/.WhisperType-DMG.XXXXXX")"
MOUNTPOINT="$STAGING/mounted"
MOUNTED=false
cleanup() {
    if "$MOUNTED"; then
        if ! hdiutil detach "$MOUNTPOINT" -quiet; then
            printf 'Could not detach verification volume. Temporary files preserved at %s\n' "$STAGING" >&2
            return
        fi
    fi
    rm -rf -- "$STAGING"
}
trap cleanup EXIT
ls -d "$STAGING" >/dev/null
mkdir "$STAGING/contents" "$MOUNTPOINT"
ditto "$APP" "$STAGING/contents/WhisperType.app"
ln -s /Applications "$STAGING/contents/Applications"
cp "$PROJECT_ROOT/Resources/Install.txt" "$STAGING/contents/Install.txt"

hdiutil create -volname "WhisperType" -fs HFS+ -srcfolder "$STAGING/contents" \
    -format UDZO -imagekey zlib-level=9 "$STAGING/$NAME"
hdiutil verify "$STAGING/$NAME"
hdiutil attach "$STAGING/$NAME" -mountpoint "$MOUNTPOINT" -readonly -nobrowse -noautoopen -quiet
MOUNTED=true
codesign --verify --strict --verbose=2 "$MOUNTPOINT/WhisperType.app"
cmp "$APP/Contents/MacOS/WhisperType" "$MOUNTPOINT/WhisperType.app/Contents/MacOS/WhisperType"
[[ -L "$MOUNTPOINT/Applications" && "$(readlink "$MOUNTPOINT/Applications")" == /Applications ]]
cmp "$PROJECT_ROOT/Resources/Install.txt" "$MOUNTPOINT/Install.txt"
hdiutil detach "$MOUNTPOINT" -quiet
MOUNTED=false

# Publish only after image, mounted bundle, and installer contents pass verification.
mv -f "$STAGING/$NAME" "$OUTPUT"
shasum -a 256 "$OUTPUT"
printf '\nCreated %s\nDrag WhisperType into Applications to install. This local build is not notarized.\n' "$OUTPUT"
