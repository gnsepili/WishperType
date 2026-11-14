# Privacy And Data Flow

WhisperType is a personal native macOS prototype using your OpenAI API account. It is not an offline transcription system, a zero-retention service, or an audited security product. Review the content you send and the policies of your API project before using sensitive material.

## What Leaves The Mac

| Operation | Data sent | Destination |
| --- | --- | --- |
| Accurate / file transcription | Completed microphone audio, model/language settings, vocabulary hints | `https://api.openai.com/v1/audio/transcriptions` |
| Live transcription | PCM microphone audio while recording, model/language settings, vocabulary hints | `wss://api.openai.com/v1/realtime?intent=transcription` |
| Cleanup, style, translation | Transcript and applicable rewrite instructions | `https://api.openai.com/v1/responses` |
| Selected-text command / transform | Explicitly selected or supplied text and the transformation instruction | Responses API |
| Optional app context | App identity, selection, and bounded surrounding text included in rewrite context | Responses API, only when context sharing is enabled |

There is no WhisperType-hosted backend, analytics service, team server, or sync account in this project. API requests authenticate directly to OpenAI with the key held in memory. Build and test scripts do not contact these inference endpoints; HTTP tests use mocks. The API clients do not execute model-proposed tools or arbitrary commands.

Live mode sends audio before you finish speaking. If Live mode fails and falls back to file transcription, the same recording may be transmitted again through the REST endpoint. Cancellation cannot retract bytes already received or reverse charges already incurred.

## Context Is Opt-In

`contextEnabled` defaults to `false`. Ordinary dictation does not send selected/surrounding app text as ambient rewrite context when this option is off. The insertion service may still inspect a local Accessibility snapshot to ensure that focus, field contents, and selection have not changed before writing. This local safety snapshot is separate from opting to send context to the provider.

**An explicit selected-text command is different.** Invoking a spoken command or transform on a selection authorizes sharing that selection as the task's input, even with ambient context disabled. Do not select confidential text and invoke a transform unless you intend to transmit it. Similarly, transforming scratchpad text explicitly submits that supplied text. App-specific and custom instructions can themselves contain sensitive information; avoid secrets in those fields.

No screen images, continuous desktop recordings, system/loopback audio, or meeting-bot capture are implemented. Hotkeys inspect configured keycodes and modifier state, not a log of your typed text. Secure-field checks are conservative, but compatibility with every custom application cannot be guaranteed.

## What Stays Locally

Default location: `~/Library/Application Support/WhisperType/`.

| Item | Stored content | Default policy |
| --- | --- | --- |
| `settings.json` | Models, preferences, custom instructions, retention settings | Persisted; no API-key field exists in `AppSettings` |
| `library.json` | Vocabulary, snippets, app rules, transforms | Persisted until edited/deleted; not history-retention controlled |
| `history.json` | Transcripts, results, app identity, timestamps, duration/latency, status/errors, optional audio reference and command source text | History enabled, 30-day retention |
| `scratchpad.txt` | Text you keep in the scratchpad | Persisted until edited/cleared; not history-retention controlled |
| `Audio/<UUID>.m4a` | Microphone recording used for processing; optionally kept with history | Retaining audio is off by default |
| Login Keychain | OpenAI API key | Device-only, accessible while unlocked, not iCloud-synchronizable |

Audio retention being off does **not** mean no local recording file is ever written. Recordings are needed during processing and REST fallback. Completed job cleanup/retention removes associated audio according to the current settings. An app crash or failed deletion can leave a file behind. In-memory results may remain for copy/paste while the app is running even when history saving is disabled.

The Keychain integration uses service `com.whispertype.mac`, account `api-key`, with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and synchronization disabled. It reports Keychain errors rather than writing a plaintext fallback. Ad-hoc rebuilds can change signing identity requirements and trigger another access prompt. No stable permission or Keychain-consent continuity is promised by local signing.

## Filesystem Protection

The store creates its application directory and `Audio` subdirectory with POSIX `0700`. JSON and scratchpad data are written to private `0600` temporary files before atomic same-directory replacement; existing files read by the store are tightened to `0600`. The audio writer is responsible for setting `0600` on recordings when it creates them. These permissions restrict other ordinary macOS users, not administrators or other processes running as your account.

This is not application-level encryption. FileVault, device login security, backups, ACLs, and your OS configuration still matter. Do not use a shared/untrusted parent directory when passing a custom `AppStore(root:)`. The store rejects symlinked storage directories and data files, and audio paths reject traversal and symlink targets, but this is not a security boundary against a malicious process already controlling your account.

Missing files produce defaults. Corrupt JSON, invalid UTF-8, unsafe file types, and I/O failures are errors, not permission to reset stored data. Atomic replacement prevents a normal reader from seeing a half-written file; it is not a transaction across settings, history, and audio, or a promise of survival under every storage/power failure.

## Retention And Deletion

- History expires after the configured number of elapsed 24-hour periods; default 30 days. Pruning happens when the app invokes it, not via an OS background service while the app is closed.
- Turning off history retention purges supplied history and its referenced audio, regardless of the audio-retention setting.
- Turning off audio retention deletes audio referenced by supplied history entries and clears their audio filenames, while keeping text if history remains enabled.
- With audio retention enabled, a file shared by multiple entries is kept while at least one retained entry still references it.
- Pruning deliberately does not sweep the audio directory: files without history entries can belong to recordings or queued jobs still in flight. No automatic startup orphan sweep is implemented, including for files older than 24 hours.
- Deletion is ordinary filesystem removal, not forensic erasure. Copies may remain in filesystem snapshots, backups, previously exported files, the clipboard, or a provider's records.
- A deletion/save error is surfaced to the app. Partial cleanup is possible, and retrying a missing audio file is safe. Do not assume the new policy has fully applied if the app reports a storage error.

To fully inspect or remove local data, quit WhisperType first so no recording/job is active. Review the application-support folder and any exported copies. Clearing history does not clear your vocabulary, custom instructions, scratchpad, exports, or Keychain key. Remove the key separately using the app's key controls or Keychain Access. Deleting the `.app` alone does not remove application-support data or Keychain items. Local deletion cannot remove data already transmitted to OpenAI.

## Provider Policy

According to [OpenAI's API data controls documentation](https://platform.openai.com/docs/guides/your-data), checked September 6, 2026, API inputs/outputs are not used to train models by default unless you opt in. **Not used for training does not mean not retained.** Endpoint, model, project controls, legal requirements, and your agreement affect storage and abuse-monitoring policies.

The current provider table lists no abuse-monitoring/application-state retention for `/v1/audio/transcriptions`, and ordinarily up to 30 days of abuse-monitoring retention for `/v1/realtime` and `/v1/responses`, subject to the documented exceptions. WhisperType sends `store: false` for Responses requests to opt out of ordinary response application-state storage; that is not the same as an approved zero-data-retention agreement and does not override provider abuse monitoring or other exceptions.

Review the provider's current terms and your account's data controls. This app does not negotiate zero retention, certify residency/compliance, route to a regional endpoint, or promise that all APIs have identical policies. Avoid regulated or employer-restricted content unless your use is authorized.

## Permissions And Clipboard

- Microphone permission enables recording when you start dictation.
- Accessibility permission supports inspecting focused editable fields and guarded insertion. The app is unsandboxed for this global desktop integration, not granted unrestricted access by the audio entitlement.
- Input Monitoring enables global shortcut detection. It is not used to persist general keystrokes.
- Launch-at-login registration is optional and uses macOS Service Management. Test and approve it interactively.
- Paste fallback temporarily puts the result on the system clipboard. Clipboard restoration is enabled by default and avoids overwriting a newer clipboard change, but other clipboard tools can observe temporary content. Explicit Copy intentionally replaces the clipboard.

Builds are local, ad-hoc signed, and not notarized. There is no claim of an external privacy/security audit. Do not run the prototype unattended on sensitive documents before testing the permission, focus, cancellation, and retention behavior yourself.
