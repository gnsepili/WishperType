# Local Storage

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

`AppStore` creates its root and `Audio` with POSIX mode `0700`. JSON and scratchpad writes use a private `0600` temporary file, synchronize its contents, then rename atomically in the same directory. Existing persisted files are restricted to `0600` when loaded. Audio is created by the recorder, which must apply `0600`; a URL alone cannot set a future file's mode. These are access permissions, not application-level encryption. See [Privacy](PRIVACY.md) for cloud processing and storage caveats.

Missing files return defaults without writing anything. Corrupt JSON, invalid UTF-8, unsafe file types, permissions problems, and other I/O errors throw. There is no silent reset, migration layer, or automatic replacement of corrupt data. If startup reports a storage failure, preserve the original files and resolve it before saving default state.

## Persistence Contract

The public interface in [`Sources/WhisperCore/Persistence.swift`](../Sources/WhisperCore/Persistence.swift) is synchronous; serialize read/modify/write operations at the app layer. It is not a multi-process database.

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
