import Darwin
import Foundation

/// Local, synchronous storage. The caller serializes read/modify/write operations.
public final class AppStore {
    public let root: URL
    public let audioDirectory: URL

    public init(root: URL? = nil) throws {
        let directory = try root ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("WhisperType", isDirectory: true)
        guard directory.isFileURL, directory.standardizedFileURL.path != "/" else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        self.root = directory.standardizedFileURL
        self.audioDirectory = self.root.appendingPathComponent("Audio", isDirectory: true)
        for url in [self.root, audioDirectory] {
            if try Self.attributes(at: url) == nil {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
            try Self.checkDirectory(url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }

    public func loadSettings() throws -> AppSettings {
        try loadJSON("settings.json", default: AppSettings())
    }

    public func saveSettings(_ settings: AppSettings) throws {
        try saveJSON(settings, fileName: "settings.json")
    }

    public func loadLibrary() throws -> LibraryData {
        try loadJSON("library.json", default: LibraryData())
    }

    public func saveLibrary(_ library: LibraryData) throws {
        try saveJSON(library, fileName: "library.json")
    }

    public func loadHistory() throws -> [HistoryEntry] {
        try loadJSON("history.json", default: [])
    }

    public func saveHistory(_ history: [HistoryEntry]) throws {
        try saveJSON(history, fileName: "history.json")
    }

    public func loadScratchpad() throws -> String {
        guard let data = try read("scratchpad.txt") else { return "" }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }

    public func saveScratchpad(_ text: String) throws {
        try write(Data(text.utf8), fileName: "scratchpad.txt")
    }

    /// Returns only a plain basename inside Audio; symlinks and directories are refused.
    public func audioURL(for fileName: String) -> URL? {
        guard !fileName.isEmpty, !fileName.hasPrefix("."),
              !fileName.contains(where: { "/\\:%".contains($0) || $0.isNewline }),
              !fileName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        do {
            try Self.checkDirectory(root)
            try Self.checkDirectory(audioDirectory)
            let url = audioDirectory.appendingPathComponent(fileName, isDirectory: false)
            _ = try Self.checkFile(url)
            return url
        } catch {
            return nil
        }
    }

    /// Does not create a file. The audio writer must create it with mode 0600.
    public func newRecordingURL(id: UUID = UUID()) -> URL {
        audioDirectory.appendingPathComponent(id.uuidString).appendingPathExtension("m4a")
    }

    /// Missing files are harmless; unsafe names and other filesystem failures throw.
    public func deleteAudio(fileName: String) throws {
        guard let url = audioURL(for: fileName) else { throw CocoaError(.fileWriteInvalidFileName) }
        if try Self.checkFile(url) { try FileManager.default.removeItem(at: url) }
    }

    /// Removes referenced audio and returns the new history; the caller saves that history.
    /// No directory sweep: unreferenced files may belong to in-flight recording/queued jobs.
    public func prune(history: [HistoryEntry], settings: AppSettings) throws -> [HistoryEntry] {
        let cutoff = Date().addingTimeInterval(-Double(max(0, settings.retentionDays)) * 86_400)
        var kept = history.filter {
            settings.retainHistory && settings.retentionDays > 0 && $0.createdAt >= cutoff
        }
        if !settings.retainAudio {
            for index in kept.indices { kept[index].audioFileName = nil }
        }
        // Treat differently cased/canonically equivalent names as shared on macOS volumes.
        let retainedNames = Set(kept.compactMap(\.audioFileName).map {
            $0.precomposedStringWithCanonicalMapping.lowercased()
        })
        let removedNames = Set(history.compactMap(\.audioFileName)).filter {
            !retainedNames.contains($0.precomposedStringWithCanonicalMapping.lowercased())
        }.sorted()
        // Validate all references before starting deletion, including untrusted history data.
        for name in removedNames {
            guard audioURL(for: name) != nil else { throw CocoaError(.fileWriteInvalidFileName) }
        }
        for name in removedNames { try deleteAudio(fileName: name) }
        return kept
    }

    private func loadJSON<T: Decodable>(_ fileName: String, default value: @autoclosure () -> T) throws -> T {
        guard let data = try read(fileName) else { return value() }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func saveJSON<T: Encodable>(_ value: T, fileName: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(encoder.encode(value), fileName: fileName)
    }

    private func read(_ fileName: String) throws -> Data? {
        try Self.checkDirectory(root)
        let url = root.appendingPathComponent(fileName)
        guard try Self.checkFile(url) else { return nil }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return try Data(contentsOf: url)
    }

    private func write(_ data: Data, fileName: String) throws {
        try Self.checkDirectory(root)
        let destination = root.appendingPathComponent(fileName)
        _ = try Self.checkFile(destination)
        let temporary = root.appendingPathComponent(".\(UUID().uuidString).tmp")
        // Create privately before writing any bytes; rename publishes the complete file atomically.
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var closed = false
        defer {
            if !closed { try? handle.close() }
            _ = Darwin.unlink(temporary.path)
        }
        guard Darwin.fchmod(descriptor, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        closed = true
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func attributes(at url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
    }

    private static func checkDirectory(_ url: URL) throws {
        guard let attributes = try attributes(at: url),
              attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    private static func checkFile(_ url: URL) throws -> Bool {
        guard let attributes = try attributes(at: url) else { return false }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return true
    }
}
