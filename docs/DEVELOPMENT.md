# Development

- Runtime target: macOS 14 or newer.
- Development environment: Swift 6.3 CLI with the macOS SDK and Apple Command Line Tools. The package uses Swift tools 5.9 and Swift 5 language mode; a recent CLI is needed for Swift Testing.
- Full Xcode is not required by the scripts. They use `swift`, `xcrun`, `plutil`, and `codesign`.
- The release build targets the host architecture, not a universal Apple Silicon/Intel binary. macOS 14 compatibility is a deployment target, not a claim of testing on macOS 14 hardware.

From this directory:

```bash
./scripts/test.sh
./scripts/test.sh --filter PersistenceTests
./scripts/build-app.sh
```

The build script creates `dist/WhisperType.app`, bundle ID `com.whispertype.mac`, version `1.0.0`. It stages and verifies the new bundle before replacing a previous build. It does not install into `/Applications`, launch the app, ask for privacy permissions, access your API key, or call an API. It uses ad-hoc signing with hardened runtime and the microphone audio-input entitlement. The app is **not sandboxed and not notarized**. No custom app icon asset is bundled; native controls can use runtime SF Symbols.

The setup window was launched during verification. To reopen it:

```bash
open dist/WhisperType.app
```

Use the `.app` rather than `swift run` for microphone permissions, menu-bar behavior, and login-item testing. `LSUIElement` makes this a menu-bar/accessory app rather than a normal Dock app. Keep a stable bundle location for permission testing. Ad-hoc signatures can change their designated requirement after a rebuild, so macOS may ask again for Keychain or privacy access. A stable bundle ID alone does not guarantee permission continuity. Distribution requires a real signing identity, an appropriate signing policy, and notarization; this script does none of those.

## DMG Installation

`dist/WhisperType-1.0.0-arm64.dmg` is the installer image for Apple Silicon Macs running macOS 14 or later. Quit any running development copy, open the DMG, drag **WhisperType** onto **Applications**, eject the image, and launch the installed app from Applications.

If macOS blocks this unnotarized test build, try opening the installed app once, then use **System Settings > Privacy & Security > Open Anyway** if offered. Do not disable Gatekeeper globally. Grant permissions to the installed copy; macOS may require removing obsolete development-copy entries and restarting the app.

To package an existing verified app without rebuilding or changing its signature:

```bash
./scripts/build-dmg.sh
```

For a fresh source build, run `./scripts/build-app.sh` first. The DMG script derives the version and architecture from the actual bundle, adds an Applications shortcut and installation instructions, creates a compressed image, mounts it read-only, verifies the app signature and executable bytes, then detaches it. It prints the image's SHA-256 checksum. No user settings, recordings, history, or API credentials are packaged, and the script does not install the app or grant permissions.

## Command Line Tools Testing

Some CLT installations contain Swift Testing outside the SDK's normal framework search paths. On the development machine, it is at:

```text
/Library/Developer/CommandLineTools/Library/Developer/Frameworks/Testing.framework
```

Here `xcrun --show-sdk-platform-path` fails because full Xcode is absent. `scripts/test.sh` tries that path when available, then the active developer directory and SDK framework locations. It supplies `-F` to the Swift compiler and linker and matching linker `-rpath` entries for the frameworks and, when present, the adjacent `usr/lib/lib_TestingInterop.dylib`. This handles both compile-time imports and runtime loading. It explicitly enables Swift Testing and disables XCTest, which this test target does not use. These flags are test-only; they are not embedded in the release app. Extra arguments are forwarded to `swift test`, for example `--configuration release` or `--filter PersistenceTests`.

If `import Testing` still fails, inspect `swift --version`, `xcode-select -p`, and `xcrun --sdk macosx --show-sdk-path`. Use a matching recent Swift/CLT installation instead of adding a package dependency or hard-coding someone else's SDK version.

## Validation Scope

The automated tests use Swift Testing, temporary directories, and mocked HTTP responses. Persistence tests cover round trips, missing versus corrupt data, permissions, atomic replacement, traversal/symlink rejection, retention settings, shared references, and in-flight audio preservation. No actual OpenAI key or microphone is required by the tests.

Verification on September 7, 2026, with Swift 6.3.3 on Apple Silicon:

- **104 tests passed in six suites**, including the opt-in native render check.
- Strict-concurrency compilation with warnings treated as errors passed in Swift 5 language mode.
- Release compilation, resource plist validation, and strict ad-hoc code-signature verification passed.
- The bundled app launched successfully. macOS reported its main window and setup sheet on screen.
- Windowless SwiftUI rendering passed at 1100 x 740 and 860 x 600 points. Native sidebar rows are not included in that windowless rendering, so it is a layout smoke test, not exhaustive visual validation.
- Native shortcut tests use synthetic events without posting them. Realtime tests exercise configuration, pre-commit deltas, ordering, bounded buffers, and cancellation without connecting to OpenAI.

To enable the optional render check, supply a PNG destination in an existing temporary directory:

```bash
WHISPERTYPE_PREVIEW_PATH="$TMPDIR/whispertype-preview.png" ./scripts/test.sh
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

Without `WHISPERTYPE_PREVIEW_PATH`, the render check is deliberately skipped. `--skip-build` only runs previously built tests and must not be used as proof that changed sources compile.

No OpenAI API key was available during development. Automated success does not verify TCC permission prompts, Keychain consent across rebuilds, microphone hardware, actual API billing/model access, realtime service behavior, launch-at-login registration, or insertion into real third-party applications. No transcription accuracy or latency comparison against Wispr Flow has been performed.

For a manual acceptance pass: use a non-sensitive recording, test hold/toggle/cancel, change focus during processing, try a selected-text command, test a failed API request, confirm history/audio retention after restart, and test clipboard restoration after both successful and refused insertion. Longer recordings and Live-to-REST fallback need separate network-enabled checks.
