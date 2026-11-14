import Foundation
import Testing
@testable import WhisperCore

struct PersistenceTests {
    private func withStore(_ body: (AppStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperType-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(AppStore(root: root))
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    @Test func missingFilesReturnDefaultsWithoutWritingThem() throws {
        try withStore { store in
            #expect(try store.loadSettings() == AppSettings())
            let library = try store.loadLibrary()
            #expect(library.vocabulary.isEmpty)
            #expect(library.snippets.isEmpty)
            #expect(library.appRules.isEmpty)
            #expect(library.transforms == CustomTransform.defaults)
            #expect(try store.loadHistory().isEmpty)
            #expect(try store.loadScratchpad() == "")
            #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path) == ["Audio"])
        }
    }

    @Test func settingsAndLibraryRoundTripAcrossInstances() throws {
        try withStore { store in
            var settings = AppSettings()
            settings.style = .developer
            settings.cleanup = .polished
            settings.processingMode = .live
            settings.language = "hi"
            settings.translationLanguage = "English"
            settings.contextEnabled = true
            settings.retainAudio = true
            settings.retentionDays = 7
            settings.customInstructions = "Keep identifiers and \u{6771}\u{4EAC} intact."
            try store.saveSettings(settings)
            var library = LibraryData()
            library.vocabulary = [.init(term: "WhisperType", heardAs: "whisper type")]
            library.snippets = [.init(trigger: "sign off", expansion: "Thanks,\nGanesh")]
            library.appRules = [.init(bundleID: "com.apple.mail", appName: "Mail", style: .email, instructions: "Warm tone")]
            library.transforms.append(.init(name: "Translate", instruction: "Translate to Hindi"))
            try store.saveLibrary(library)

            let reopened = try AppStore(root: store.root)
            #expect(try reopened.loadSettings() == settings)
            let loaded = try reopened.loadLibrary()
            #expect(loaded.vocabulary == library.vocabulary)
            #expect(loaded.snippets == library.snippets)
            #expect(loaded.appRules == library.appRules)
            #expect(loaded.transforms == library.transforms)
        }
    }

    @Test func historyAndScratchpadRoundTripWithoutLosingFieldsOrWhitespace() throws {
        try withStore { store in
            let history: [HistoryEntry] = [
                .init(createdAt: Date(timeIntervalSince1970: 1_700_000_000.125), duration: 12.5,
                      targetApp: "Mail", bundleID: "com.apple.mail", rawText: "raw", text: "Polished.",
                      audioFileName: "recording.m4a", latency: 0.75, inserted: true),
                .init(status: .failed, error: "No network", isCommand: true, originalText: "Original"),
                .init(status: .cancelled)
            ]
            let scratchpad = "  First\tline\r\n\u{1F399} \u{6771}\u{4EAC}\n\n"
            try store.saveHistory(history)
            try store.saveScratchpad(scratchpad)
            let reopened = try AppStore(root: store.root)
            #expect(try reopened.loadHistory() == history)
            #expect(try reopened.loadScratchpad() == scratchpad)
            try reopened.saveHistory([])
            try reopened.saveScratchpad("")
            #expect(try reopened.loadHistory().isEmpty)
            #expect(try reopened.loadScratchpad().isEmpty)
        }
    }

    @Test func directoriesAndSavedFilesArePrivateIncludingReplacements() throws {
        try withStore { store in
            #expect(try permissions(store.root) == 0o700)
            #expect(try permissions(store.audioDirectory) == 0o700)
            for _ in 0..<2 {
                try store.saveSettings(.init())
                try store.saveLibrary(.init())
                try store.saveHistory([])
                try store.saveScratchpad("private")
                for name in ["settings.json", "library.json", "history.json", "scratchpad.txt"] {
                    #expect(try permissions(store.root.appendingPathComponent(name)) == 0o600)
                }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.root.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.audioDirectory.path)
            _ = try AppStore(root: store.root)
            #expect(try permissions(store.root) == 0o700)
            #expect(try permissions(store.audioDirectory) == 0o700)
            let scratchpad = store.root.appendingPathComponent("scratchpad.txt")
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: scratchpad.path)
            #expect(try store.loadScratchpad() == "private")
            #expect(try permissions(scratchpad) == 0o600)
        }
    }

    @Test func atomicReplacementLeavesExistingOpenReaderOnOldCompleteFile() throws {
        try withStore { store in
            try store.saveScratchpad("old complete value")
            let reader = try FileHandle(forReadingFrom: store.root.appendingPathComponent("scratchpad.txt"))
            defer { try? reader.close() }
            try store.saveScratchpad("new complete value")
            #expect(try reader.readToEnd() == Data("old complete value".utf8))
            #expect(try store.loadScratchpad() == "new complete value")
            #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path).sorted() == ["Audio", "scratchpad.txt"])
        }
    }

    @Test func encodingFailurePreservesPreviousJSONAndLeavesNoTemporaryFiles() throws {
        try withStore { store in
            let settings = AppSettings()
            try store.saveSettings(settings)
            let original = try Data(contentsOf: store.root.appendingPathComponent("settings.json"))
            var invalid = settings
            invalid.maxRecordingSeconds = .infinity
            #expect(throws: (any Error).self) { try store.saveSettings(invalid) }
            #expect(try store.loadSettings() == settings)
            #expect(try Data(contentsOf: store.root.appendingPathComponent("settings.json")) == original)
            #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path).sorted() == ["Audio", "settings.json"])
        }
    }

    @Test(arguments: ["settings.json", "library.json", "history.json"])
    func corruptJSONThrowsAndIsNotReset(fileName: String) throws {
        try withStore { store in
            let url = store.root.appendingPathComponent(fileName)
            for corrupt in [Data(), Data("{broken".utf8), Data("null".utf8), Data("{\"unexpected\":true}".utf8)] {
                try corrupt.write(to: url)
                #expect(throws: (any Error).self) {
                    switch fileName {
                    case "settings.json": _ = try store.loadSettings()
                    case "library.json": _ = try store.loadLibrary()
                    default: _ = try store.loadHistory()
                    }
                }
                #expect(try Data(contentsOf: url) == corrupt)
            }
        }
    }

    @Test func invalidScratchpadEncodingThrowsInsteadOfReplacingCharacters() throws {
        try withStore { store in
            let url = store.root.appendingPathComponent("scratchpad.txt")
            let invalid = Data([0xFF, 0xFE, 0xFF])
            try invalid.write(to: url)
            #expect(throws: (any Error).self) { try store.loadScratchpad() }
            #expect(try Data(contentsOf: url) == invalid)
        }
    }

    @Test func filesystemErrorsAreNotTreatedAsMissingFiles() throws {
        try withStore { store in
            try FileManager.default.createDirectory(at: store.root.appendingPathComponent("settings.json"),
                                                    withIntermediateDirectories: false)
            #expect(throws: (any Error).self) { try store.loadSettings() }
            #expect(throws: (any Error).self) { try store.saveSettings(.init()) }
            try FileManager.default.removeItem(at: store.root)
            #expect(throws: (any Error).self) { try store.loadHistory() }
            #expect(throws: (any Error).self) { try store.saveScratchpad("must fail") }
        }
    }

    @Test func inaccessibleDirectorySurfacesAnError() throws {
        try withStore { store in
            try store.saveSettings(.init())
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: store.root.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.root.path) }
            #expect(throws: (any Error).self) { try store.loadSettings() }
            #expect(throws: (any Error).self) { try store.saveSettings(.init()) }
        }
    }

    @Test func recordingURLsHaveStableIDsAndDoNotCreateFiles() throws {
        try withStore { store in
            let id = UUID()
            let url = store.newRecordingURL(id: id)
            #expect(url.lastPathComponent == "\(id.uuidString).m4a")
            #expect(url.deletingLastPathComponent().standardizedFileURL == store.audioDirectory.standardizedFileURL)
            #expect(store.audioURL(for: url.lastPathComponent) == url)
            #expect(store.newRecordingURL() != store.newRecordingURL())
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test(arguments: ["", ".", "..", "../outside.m4a", "/tmp/outside.m4a", "nested/file.m4a",
                      "nested\\file.m4a", "a/../b.m4a", "%2e%2e%2foutside.m4a", "file:///tmp/audio.m4a",
                      "bad\u{0000}.m4a", "bad\n.m4a", ".hidden.m4a"])
    func audioPathsRejectTraversalAndAmbiguousNames(fileName: String) throws {
        try withStore { store in
            #expect(store.audioURL(for: fileName) == nil)
            #expect(throws: (any Error).self) { try store.deleteAudio(fileName: fileName) }
        }
    }

    @Test func deletingAudioIsIdempotentAndDoesNotRemoveDirectoriesOrSymlinkTargets() throws {
        try withStore { store in
            let file = try #require(store.audioURL(for: "speech with spaces.m4a"))
            try Data("audio".utf8).write(to: file)
            try store.deleteAudio(fileName: file.lastPathComponent)
            try store.deleteAudio(fileName: file.lastPathComponent)
            #expect(!FileManager.default.fileExists(atPath: file.path))

            let outside = store.root.appendingPathComponent("outside.m4a")
            try Data("untouched".utf8).write(to: outside)
            let symlink = store.audioDirectory.appendingPathComponent("link.m4a")
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
            #expect(store.audioURL(for: "link.m4a") == nil)
            #expect(throws: (any Error).self) { try store.deleteAudio(fileName: "link.m4a") }
            #expect(try Data(contentsOf: outside) == Data("untouched".utf8))
            let directory = store.audioDirectory.appendingPathComponent("folder.m4a")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            #expect(store.audioURL(for: "folder.m4a") == nil)
            #expect(throws: (any Error).self) { try store.deleteAudio(fileName: "folder.m4a") }
        }
    }

    @Test func symlinkedPersistenceAndStorageDirectoriesAreRefused() throws {
        try withStore { store in
            let outside = store.root.appendingPathComponent("outside.txt")
            try Data("untouched".utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(at: store.root.appendingPathComponent("scratchpad.txt"),
                                                      withDestinationURL: outside)
            #expect(throws: (any Error).self) { try store.loadScratchpad() }
            #expect(throws: (any Error).self) { try store.saveScratchpad("overwrite") }
            #expect(try Data(contentsOf: outside) == Data("untouched".utf8))
            let rootLink = store.root.appendingPathComponent("linked-root")
            try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: store.root)
            #expect(throws: (any Error).self) { try AppStore(root: rootLink) }

            try FileManager.default.removeItem(at: store.audioDirectory)
            try FileManager.default.createSymbolicLink(at: store.audioDirectory, withDestinationURL: store.root)
            #expect(store.audioURL(for: "outside.txt") == nil)
            #expect(throws: (any Error).self) { try store.deleteAudio(fileName: "outside.txt") }
            #expect(throws: (any Error).self) { try AppStore(root: store.root) }
            #expect(try Data(contentsOf: outside) == Data("untouched".utf8))
        }
    }

    @Test func nonFileRootIsRejected() throws {
        #expect(throws: (any Error).self) { try AppStore(root: URL(string: "https://example.com/data")!) }
    }

    @Test func pruningExpiresOldHistoryButKeepsRecentOrderAndUnreferencedRecordings() throws {
        try withStore { store in
            var settings = AppSettings()
            settings.retainAudio = true
            let old = HistoryEntry(createdAt: Date().addingTimeInterval(-31 * 86_400), audioFileName: "old.m4a")
            let recent = HistoryEntry(audioFileName: "recent.m4a")
            let another = HistoryEntry(status: .failed, audioFileName: "missing.m4a")
            for name in ["old.m4a", "recent.m4a", "in-flight.m4a", "unreferenced.m4a"] {
                try Data("audio".utf8).write(to: #require(store.audioURL(for: name)))
            }
            let orphan = try #require(store.audioURL(for: "unreferenced.m4a"))
            try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: orphan.path)
            let history = [recent, old, another]
            try store.saveHistory(history)
            #expect(try store.prune(history: history, settings: settings) == [recent, another])
            #expect(!FileManager.default.fileExists(atPath: store.audioDirectory.appendingPathComponent("old.m4a").path))
            for name in ["recent.m4a", "in-flight.m4a", "unreferenced.m4a"] {
                #expect(FileManager.default.fileExists(atPath: store.audioDirectory.appendingPathComponent(name).path))
            }
            #expect(try store.loadHistory() == history) // prune does not implicitly commit history.
        }
    }

    @Test func disablingAudioDeletesReferencedFilesAndClearsKeptReferences() throws {
        try withStore { store in
            let url = store.newRecordingURL()
            try Data("audio".utf8).write(to: url)
            let entry = HistoryEntry(text: "keep the text", audioFileName: url.lastPathComponent)
            var expected = entry
            expected.audioFileName = nil
            #expect(try store.prune(history: [entry], settings: .init()) == [expected])
            #expect(!FileManager.default.fileExists(atPath: url.path))
            #expect(try store.prune(history: [entry], settings: .init()) == [expected])
        }
    }

    @Test(arguments: [true, false])
    func disablingHistoryDeletesAllReferencedAudioRegardlessOfAudioPreference(retainAudio: Bool) throws {
        try withStore { store in
            var settings = AppSettings()
            settings.retainHistory = false
            settings.retainAudio = retainAudio
            let url = store.newRecordingURL()
            let inFlight = store.newRecordingURL()
            try Data("audio".utf8).write(to: url)
            try Data("in flight".utf8).write(to: inFlight)
            #expect(try store.prune(history: [.init(audioFileName: url.lastPathComponent)], settings: settings).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: url.path))
            #expect(FileManager.default.fileExists(atPath: inFlight.path))
        }
    }

    @Test(arguments: [0, -1, Int.min])
    func nonpositiveRetentionExpiresEverything(days: Int) throws {
        try withStore { store in
            var settings = AppSettings()
            settings.retentionDays = days
            let pruned = try store.prune(history: [.init(createdAt: .distantFuture)], settings: settings)
            #expect(pruned.isEmpty)
        }
    }

    @Test func veryLargeRetentionDoesNotOverflow() throws {
        try withStore { store in
            var settings = AppSettings()
            settings.retentionDays = Int.max
            let entry = HistoryEntry()
            let pruned = try store.prune(history: [entry], settings: settings)
            #expect(pruned == [entry])
        }
    }

    @Test func sharedAudioSurvivesUntilItsLastRetainedReferenceIsGone() throws {
        try withStore { store in
            var settings = AppSettings()
            settings.retainAudio = true
            let url = try #require(store.audioURL(for: "shared.m4a"))
            try Data("audio".utf8).write(to: url)
            let old = HistoryEntry(createdAt: .distantPast, audioFileName: "shared.m4a")
            let recent = HistoryEntry(audioFileName: "shared.m4a")
            #expect(try store.prune(history: [old, recent, old], settings: settings) == [recent])
            #expect(FileManager.default.fileExists(atPath: url.path))
            var alternateCase = recent
            alternateCase.audioFileName = "SHARED.m4a"
            #expect(try store.prune(history: [old, alternateCase], settings: settings) == [alternateCase])
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(try store.prune(history: [old, old], settings: settings).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func unsafeHistoryReferenceThrowsBeforeAnyDeletion() throws {
        try withStore { store in
            let url = store.newRecordingURL()
            try Data("audio".utf8).write(to: url)
            let history: [HistoryEntry] = [.init(audioFileName: url.lastPathComponent), .init(audioFileName: "../outside.m4a")]
            #expect(throws: (any Error).self) { try store.prune(history: history, settings: .init()) }
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }
}
