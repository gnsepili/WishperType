#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(dirname -- "$SCRIPT_DIR")"
[[ -f "$PROJECT_ROOT/Package.swift" ]] || { printf '%s\n' "Package.swift not found." >&2; exit 1; }
ls -d "$PROJECT_ROOT" >/dev/null

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
DEVELOPER_DIR_PATH="$(xcode-select -p)"
PLATFORM_PATH="$(xcrun --sdk macosx --show-sdk-platform-path 2>/dev/null || true)"
FRAMEWORKS=""
for candidate in \
    "${PLATFORM_PATH:+$PLATFORM_PATH/Developer/Library/Frameworks}" \
    "$DEVELOPER_DIR_PATH/Library/Developer/Frameworks" \
    "$DEVELOPER_DIR_PATH/Library/Frameworks" \
    "$SDK_PATH/System/Library/Frameworks"; do
    if [[ -n "$candidate" && -d "$candidate/Testing.framework" ]]; then
        FRAMEWORKS="$candidate"
        break
    fi
done

TEST_COMMAND=(swift test --package-path "$PROJECT_ROOT" --sdk "$SDK_PATH"
              --enable-swift-testing --disable-xctest)
if [[ -n "$FRAMEWORKS" ]]; then
    printf 'Swift Testing frameworks: %s\n' "$FRAMEWORKS"
    TEST_COMMAND+=(-Xswiftc -F -Xswiftc "$FRAMEWORKS"
                   -Xlinker -F -Xlinker "$FRAMEWORKS"
                   -Xlinker -rpath -Xlinker "$FRAMEWORKS")
    # CLT's Testing framework has an additional interop dylib outside Frameworks.
    for library_dir in "$FRAMEWORKS/../usr/lib" "$FRAMEWORKS/../../usr/lib"; do
        if [[ -f "$library_dir/lib_TestingInterop.dylib" ]]; then
            TEST_COMMAND+=(-Xlinker -rpath -Xlinker "$library_dir")
            break
        fi
    done
else
    printf '%s\n' "No separate Testing.framework found; using the toolchain's default module paths."
fi

# CLT ships Swift Testing but not necessarily XCTest. All project tests use Testing.
# Forward e.g. --filter PersistenceTests or --configuration release to SwiftPM.
exec "${TEST_COMMAND[@]}" "$@"
