# WhisperType

A personal native macOS dictation prototype: record speech, transcribe it with your OpenAI API key, optionally rewrite it, and insert the result into a compatible focused text field. Built with SwiftUI, AppKit, AVFoundation, and other Apple frameworks. No third-party Swift package dependencies.

This is not a shipped, notarized product or a feature-complete replacement for Wispr Flow. No comparative speed or accuracy benchmark has been performed. Live microphone capture, API access, realtime behavior, and insertion across applications require a manual end-to-end check on your Mac. See the [feature matrix](docs/FEATURES.md) for implemented scope and deliberate gaps.

## Build And Test

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

### DMG Installation

`dist/WhisperType-1.0.0-arm64.dmg` is the installer image for Apple Silicon Macs running macOS 14 or later. Quit any running development copy, open the DMG, drag **WhisperType** onto **Applications**, eject the image, and launch the installed app from Applications.

If macOS blocks this unnotarized test build, try opening the installed app once, then use **System Settings > Privacy & Security > Open Anyway** if offered. Do not disable Gatekeeper globally. Grant permissions to the installed copy; macOS may require removing obsolete development-copy entries and restarting the app.

To package an existing verified app without rebuilding or changing its signature:

```bash
./scripts/build-dmg.sh
```

For a fresh source build, run `./scripts/build-app.sh` first. The DMG script derives the version and architecture from the actual bundle, adds an Applications shortcut and installation instructions, creates a compressed image, mounts it read-only, verifies the app signature and executable bytes, then detaches it. It prints the image's SHA-256 checksum. No user settings, recordings, history, or API credentials are packaged, and the script does not install the app or grant permissions.

### Command Line Tools Testing

Some CLT installations contain Swift Testing outside the SDK's normal framework search paths. On the development machine, it is at:

```text
/Library/Developer/CommandLineTools/Library/Developer/Frameworks/Testing.framework
```

Here `xcrun --show-sdk-platform-path` fails because full Xcode is absent. `scripts/test.sh` tries that path when available, then the active developer directory and SDK framework locations. It supplies `-F` to the Swift compiler and linker and matching linker `-rpath` entries for the frameworks and, when present, the adjacent `usr/lib/lib_TestingInterop.dylib`. This handles both compile-time imports and runtime loading. It explicitly enables Swift Testing and disables XCTest, which this test target does not use. These flags are test-only; they are not embedded in the release app. Extra arguments are forwarded to `swift test`, for example `--configuration release` or `--filter PersistenceTests`.

If `import Testing` still fails, inspect `swift --version`, `xcode-select -p`, and `xcrun --sdk macosx --show-sdk-path`. Use a matching recent Swift/CLT installation instead of adding a package dependency or hard-coding someone else's SDK version.

## Setup

1. Create an OpenAI API project/key with billing and access to the models you select. A ChatGPT subscription does not include API usage. See [API pricing](https://openai.com/api/pricing/) and set project usage limits appropriate to your account.
2. Enter the key in the app's Settings. The integration stores it in the macOS login Keychain, service `com.whispertype.mac`, account `api-key`, not in settings JSON. Do not put keys in source files or custom instructions.
3. Grant Microphone permission for capture. Grant Accessibility for guarded text insertion and global shortcuts, and Input Monitoring for observing the configured shortcut keycodes. Use the app's permission controls/System Settings; the build and tests do not grant permissions for you.
4. Start with a short, non-sensitive sentence in TextEdit and Accurate mode. Review the returned text before trying important documents. If focus or the field changed during processing, automatic insertion may be refused; use explicit copy/paste instead.
5. Try Live mode only after file transcription works. Realtime model availability, quotas, and protocol support depend on your API account. An unsuccessful live session can fall back to REST transcription of the recorded file, increasing latency and potentially incurring both sessions' usage charges.

Defaults from `AppSettings`:

| Setting | Default |
| --- | --- |
| REST transcription | `gpt-4o-transcribe` |
| Realtime transcription | `gpt-live-transcribe` |
| Text rewrite | `gpt-4.1-mini` |
| Processing | Accurate: record, then process |
| Cleanup/style | Light / natural |
| Surrounding app context sharing | Off |
| Local history | On, 30 days |
| Saved audio | Off |
| Clipboard restoration | On |
| Maximum recording duration | 1,200 seconds (20 minutes) |

REST mode uploads the completed recording; it is not incremental live transcription. Live mode streams microphone PCM and displays interim text when the selected model emits it; `gpt-live-transcribe` supports pre-commit deltas, while older transcription models can wait until Stop. Separately, "While a result is processing" selects "Queue new recordings" or "Wait before recording again." The serial asynchronous job queue allows processing without blocking the UI; waiting is the simpler synchronous user experience, not a synchronous network call on the main thread. Model names are configurable and are not guarantees of account access or output quality.

### Shortcuts

| Action | Shortcut |
| --- | --- |
| Hold to dictate | Control + Option by default; Right Option or Fn/Globe presets |
| Toggle dictation | Control + Option + Space |
| Hold spoken command on selected text | Control + Option + Command |
| Transform selected text | Control + Option + P |
| Copy last result | Control + Command + C |
| Paste last result | Control + Command + V |
| Cancel an active operation | Escape |

Modifier-only shortcuts can conflict with macOS, VoiceOver, input methods, and other tools. Fn/Globe behavior depends on keyboard/system settings. Secure fields, some custom controls, remote desktops, and apps with incomplete Accessibility support may refuse insertion. WhisperType does not promise to type into every app.

## Local Storage

Default root: `~/Library/Application Support/WhisperType/`.

```text
WhisperType/
  settings.json
  library.json
  history.json
  scratchpad.txt
  Audio/
    <UUID>.m4a
```

`AppStore` creates its root and `Audio` with POSIX mode `0700`. JSON and scratchpad writes use a private `0600` temporary file, synchronize its contents, then rename atomically in the same directory. Existing persisted files are restricted to `0600` when loaded. Audio is created by the recorder, which must apply `0600`; a URL alone cannot set a future file's mode. These are access permissions, not application-level encryption. See [Privacy](docs/PRIVACY.md) for cloud processing and storage caveats.

Missing files return defaults without writing anything. Corrupt JSON, invalid UTF-8, unsafe file types, permissions problems, and other I/O errors throw. There is no silent reset, migration layer, or automatic replacement of corrupt data. If startup reports a storage failure, preserve the original files and resolve it before saving default state.

### Persistence Contract

The public interface in `Sources/WhisperCore/Persistence.swift` is synchronous; serialize read/modify/write operations at the app layer. It is not a multi-process database.

```swift
public final class AppStore {
    public let root: URL
    public let audioDirectory: URL
    public init(root: URL? = nil) throws
    public func loadSettings() throws -> AppSettings
    public func saveSettings(_ settings: AppSettings) throws
    public func loadLibrary() throws -> LibraryData
    public func saveLibrary(_ library: LibraryData) throws
    public func loadHistory() throws -> [HistoryEntry]
    public func saveHistory(_ history: [HistoryEntry]) throws
    public func loadScratchpad() throws -> String
    public func saveScratchpad(_ text: String) throws
    public func audioURL(for fileName: String) -> URL?
    public func newRecordingURL(id: UUID = UUID()) -> URL
    public func deleteAudio(fileName: String) throws
    public func prune(history: [HistoryEntry], settings: AppSettings) throws -> [HistoryEntry]
}
```

- `newRecordingURL` generates a UUID `.m4a` path without creating the file.
- `audioURL` accepts ordinary basenames, including spaces, but rejects hidden names, traversal, separators, URL/percent-encoded names, control characters, symlinks, and directories. `nil` can also mean that the storage directory is inaccessible.
- `deleteAudio` throws on invalid paths or deletion errors; a missing valid file is a no-op. Callers unwrap optional history filenames before calling it.
- `prune` removes history older than `retentionDays` elapsed 24-hour periods. Nonpositive days mean retain nothing. Disabling history removes all supplied entries and their audio even if audio retention is enabled.
- Disabling audio retention removes audio referenced by supplied entries and clears filenames on kept entries. With audio retention enabled, a shared file stays until no retained entry references it.
- `prune` only removes referenced audio. It never sweeps unreferenced files, even old ones, because recording or queued processing may still own them. Crash leftovers therefore need deliberate cleanup while the app is quit.
- The caller must save the returned history and surface errors: `history = try store.prune(history: history, settings: settings)` followed by `try store.saveHistory(history)`. Audio deletion and the subsequent JSON save are not one transaction; a failure can leave a history reference to a missing recording. Retrying deletion of a missing file is safe.

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

## Scope And Design

This project focuses on one person's native desktop workflow. It does not include teams, cross-device sync, mobile clients, a hosted account service, IDE workspace indexing, a meeting bot, or system/loopback audio capture. The **Meeting summary** transform summarizes text you explicitly supply; it is not a meeting notetaker or an automatic recording/transcription service for all participants.

The design direction adapts OpenDesign's `modern-minimal` and `human-approachable` sources to native macOS controls. The attempted OpenDesign 0.19.2 generation was blocked by Claude authentication; no successful generated artifact is claimed. See [Design](docs/DESIGN.md) for provenance and visual tokens, [Features](docs/FEATURES.md) for references and limitations, and [Privacy](docs/PRIVACY.md) before sending sensitive material.
