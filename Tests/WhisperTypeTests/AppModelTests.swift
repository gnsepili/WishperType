import AppKit
import SwiftUI
import Testing
import WhisperCore
@testable import WhisperType

@MainActor
@Suite(.serialized)
struct AppModelTests {
    private func withStore(_ body: (AppStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperType-AppModelTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(AppStore(root: root))
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    // All history, library content, and audio bytes in this suite are synthetic fixtures.
    @Test func isolatedDefaultsAreIdleAndHaveNoStatisticsOrSystemConnections() throws {
        try withStore { store in
            let model = AppModel(store: store, connectsToSystem: false)
            defer { model.shutdown() }

            #expect(model.settings == AppSettings())
            #expect(model.history.isEmpty)
            #expect(model.library.vocabulary.isEmpty)
            #expect(model.library.snippets.isEmpty)
            #expect(model.library.appRules.isEmpty)
            #expect(model.library.transforms == CustomTransform.defaults)
            #expect(model.scratchpad.isEmpty)
            #expect(model.lastText.isEmpty)
            #expect(model.totalWords == 0)
            #expect(model.totalAudioMinutes == 0)
            #expect(model.averageLatency == 0)
            #expect(model.phase == .idle)
            #expect(!model.isRecording)
            #expect(!model.isBusy)
            #expect(model.pendingCount == 0)
            #expect(!model.isTransforming)
            #expect(model.level == 0)
            #expect(model.elapsed == 0)
            #expect(model.liveTranscript.isEmpty)
            #expect(model.statusMessage == "Ready when you are.")
            #expect(model.errorMessage == nil)
            #expect(model.showSetup)
            #expect(!model.hasAPIKey)
            #expect(model.apiKeyDraft.isEmpty)
            #expect(!model.accessibilityGranted)
            #expect(!model.inputMonitoringGranted)
            #expect(!model.microphoneGranted)
            #expect(!model.hotkeysReady)
            #expect(model.microphones.isEmpty)
            let audioFiles = try FileManager.default.contentsOfDirectory(atPath: store.audioDirectory.path)
            #expect(audioFiles.isEmpty)
        }
    }

    @Test func statisticsUseCompletedWordsAllDurationsAndPositiveDurationCompletedLatencies() throws {
        try withStore { store in
            let entries: [HistoryEntry] = [
                .init(duration: 30, text: "Synthetic\tfirst\nresult", latency: 2),
                .init(duration: 90, text: "Synthetic second result", latency: 4),
                .init(duration: 0, text: "Synthetic transform", latency: 100, isCommand: true),
                .init(duration: 60, text: "Synthetic failed result", status: .failed, latency: 200),
                .init(duration: 60, text: "Synthetic cancelled result", status: .cancelled, latency: 300)
            ]
            try store.saveHistory(entries)
            let model = AppModel(store: store, connectsToSystem: false)
            defer { model.shutdown() }

            #expect(model.totalWords == 8)
            #expect(model.totalAudioMinutes == 4)
            #expect(model.averageLatency == 3)

            model.history = Array(entries.suffix(3))
            #expect(model.totalWords == 2)
            #expect(model.totalAudioMinutes == 2)
            #expect(model.averageLatency == 0)
        }
    }

    @Test func busyStateReflectsCaptureQueueAndTransformsIndependently() throws {
        try withStore { store in
            let model = AppModel(store: store, connectsToSystem: false)
            defer { model.shutdown() }

            for phase: CapturePhase in [.idle, .requestingPermission, .recording, .stopping] {
                model.phase = phase
                #expect(model.isRecording == (phase == .recording))
                #expect(model.isBusy == (phase != .idle))
            }
            model.phase = .idle
            model.pendingCount = 1
            #expect(model.isBusy)
            #expect(!model.isRecording)
            model.pendingCount = 0
            model.isTransforming = true
            #expect(model.isBusy)
            #expect(!model.isRecording)
            model.isTransforming = false
            #expect(!model.isBusy)
        }
    }

    @Test(arguments: [false, true])
    func startingWithoutAKeyShowsSetupBeforeRequestingCapture(command: Bool) throws {
        try withStore { store in
            let model = AppModel(store: store, connectsToSystem: false)
            defer { model.shutdown() }
            var windowRequests = 0
            model.onShowMainWindow = { windowRequests += 1 }
            model.showSetup = false

            model.startRecording(command: command)

            #expect(model.showSetup)
            #expect(windowRequests == 1)
            #expect(!model.hasAPIKey)
            #expect(model.phase == .idle)
            #expect(!model.isBusy)
            #expect(model.pendingCount == 0)
            #expect(!model.microphoneGranted)
            #expect(!model.accessibilityGranted)
            #expect(!model.inputMonitoringGranted)
            #expect(!model.hotkeysReady)
            #expect(model.microphones.isEmpty)
            #expect(model.level == 0)
            #expect(model.elapsed == 0)
            #expect(model.liveTranscript.isEmpty)
            #expect(model.history.isEmpty)
            #expect(model.errorMessage == nil)
            #expect(model.statusMessage == "Ready when you are.")
            let audioFiles = try FileManager.default.contentsOfDirectory(atPath: store.audioDirectory.path)
            #expect(audioFiles.isEmpty)
        }
    }

    @Test func corruptSettingsPreserveHistoryAndAudioDuringLoadChangesAndShutdown() throws {
        try withStore { store in
            let settingsURL = store.root.appendingPathComponent("settings.json")
            let corrupt = Data("{synthetic corrupt settings".utf8)
            try corrupt.write(to: settingsURL)
            let entries: [HistoryEntry] = [
                .init(rawText: "Synthetic raw recent", text: "Synthetic recent", audioFileName: "recent.m4a"),
                .init(createdAt: .distantPast, rawText: "Synthetic raw old", text: "Synthetic old",
                      audioFileName: "old.m4a")
            ]
            let audio = Data("Synthetic audio fixture, not a recording".utf8)
            for entry in entries {
                let name = try #require(entry.audioFileName)
                try audio.write(to: #require(store.audioURL(for: name)))
            }
            try store.saveHistory(entries)
            let historyURL = store.root.appendingPathComponent("history.json")
            let originalHistory = try Data(contentsOf: historyURL)
            let model = AppModel(store: store, connectsToSystem: false)
            defer { model.shutdown() }

            #expect(model.settings == AppSettings())
            #expect(model.errorMessage?.contains("Settings could not be read") == true)
            #expect(model.history == entries)
            #expect(model.lastText == entries[0].text)
            #expect(try Data(contentsOf: historyURL) == originalHistory)
            for entry in entries {
                let name = try #require(entry.audioFileName)
                #expect(try Data(contentsOf: #require(store.audioURL(for: name))) == audio)
            }

            // Even a privacy-setting change must not prune using unreadable settings.
            model.settings.retentionDays = 0
            model.settings.retainHistory = false
            model.shutdown()

            #expect(model.history == entries)
            #expect(try Data(contentsOf: settingsURL) == corrupt)
            #expect(try Data(contentsOf: historyURL) == originalHistory)
            for entry in entries {
                let name = try #require(entry.audioFileName)
                #expect(try Data(contentsOf: #require(store.audioURL(for: name))) == audio)
            }
        }
    }

    @Test func validSettingsPruneExpiredHistoryAndPersistBeforeReturningFromInit() throws {
        try withStore { store in
            var settings = AppSettings()
            settings.retainAudio = true
            settings.retentionDays = 7
            try store.saveSettings(settings)
            let recent = HistoryEntry(text: "Synthetic recent", audioFileName: "recent.m4a")
            let expired = HistoryEntry(createdAt: Date().addingTimeInterval(-8 * 86_400),
                                       text: "Synthetic expired", audioFileName: "expired.m4a")
            let failed = HistoryEntry(rawText: "Synthetic failed raw", status: .failed,
                                      error: "Synthetic failure", audioFileName: "failed.m4a")
            for name in ["recent.m4a", "expired.m4a", "failed.m4a"] {
                try Data("Synthetic audio".utf8).write(to: #require(store.audioURL(for: name)))
            }
            try store.saveHistory([failed, expired, recent])
            let model = AppModel(store: store, connectsToSystem: false)
            defer { model.shutdown() }

            #expect(model.errorMessage == nil)
            #expect(model.settings == settings)
            #expect(model.history == [failed, recent])
            #expect(model.lastText == recent.text)
            #expect(try store.loadHistory() == [failed, recent])
            #expect(try FileManager.default.contentsOfDirectory(atPath: store.audioDirectory.path).sorted()
                    == ["failed.m4a", "recent.m4a"])

            model.settings.retentionDays = 0
            #expect(model.history.isEmpty)
            #expect(try store.loadHistory().isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: store.audioDirectory.path).isEmpty)
        }
    }

    @Test(arguments: [CleanupLevel.light, .polished])
    func changingPipelineDoesNotDisableCleanup(cleanup: CleanupLevel) throws {
        try withStore { store in
            var settings = AppSettings()
            settings.cleanup = cleanup
            settings.pipelineEnabled = false
            try store.saveSettings(settings)
            let model = AppModel(store: store, connectsToSystem: false)
            defer { model.shutdown() }

            for enabled in [true, false] {
                model.settings.pipelineEnabled = enabled
                settings.pipelineEnabled = enabled
                #expect(model.settings == settings)
                model.shutdown()
                #expect(try store.loadSettings() == settings)
                #expect(model.errorMessage == nil)
            }
        }
    }

    @Test func loadingHistoryPreservesRawAndCommandOriginalsWithoutRestoringToClipboard() throws {
        try withStore { store in
            let entries: [HistoryEntry] = [
                .init(rawText: "Synthetic failed raw", text: "Synthetic failed output", status: .failed),
                .init(rawText: "Synthetic cancelled raw", text: "Synthetic cancelled output", status: .cancelled),
                .init(rawText: "  Synthetic raw\twords\n", text: "Synthetic cleaned words.", inserted: true),
                .init(rawText: "Synthetic instruction", text: "Synthetic edited selection", inserted: true,
                      isCommand: true, originalText: "  Synthetic original selection\n"),
                .init(rawText: "Synthetic fallback", text: "Synthetic edit without original", isCommand: true),
                .init(rawText: "Synthetic instruction with empty original", text: "Synthetic edit",
                      isCommand: true, originalText: "")
            ]
            try store.saveHistory(entries)
            let model = AppModel(store: store, connectsToSystem: false)
            defer { model.shutdown() }

            // useRawText calls copyText unconditionally for a matching ID. Do not invoke it here.
            #expect(model.history == entries)
            #expect(model.lastText == entries[2].text)
            #expect(model.history[2].rawText == "  Synthetic raw\twords\n")
            #expect(model.history[3].originalText == "  Synthetic original selection\n")
            #expect(model.history[4].originalText == nil)
            #expect(model.history[5].originalText == "")
            model.shutdown()
            #expect(try store.loadHistory() == entries)
        }
    }

    @Test func lastTextIsEmptyWhenHistoryHasNoCompletedEntry() throws {
        try withStore { store in
            try store.saveHistory([
                .init(rawText: "Synthetic failed raw", text: "Synthetic failure", status: .failed),
                .init(text: "Synthetic cancelled output", status: .cancelled)
            ])
            let model = AppModel(store: store, connectsToSystem: false)
            defer { model.shutdown() }
            #expect(model.lastText.isEmpty)
            #expect(model.totalWords == 0)
            #expect(model.averageLatency == 0)
        }
    }

    @Test func shutdownFlushesLatestScratchpadAndLibraryToPrivateLocalFiles() throws {
        try withStore { store in
            let model = AppModel(store: store, connectsToSystem: false)
            defer { model.shutdown() }
            model.scratchpad = "Synthetic superseded draft"
            model.scratchpad = "  Synthetic scratchpad\t\r\n\u{6771}\u{4EAC}\n\n"
            model.library.vocabulary = [.init(term: "SyntheticTerm", heardAs: "synthetic term")]
            model.library.snippets = [.init(trigger: "synthetic signature", expansion: "Synthetic regards,\nTest")]
            model.library.appRules = [.init(bundleID: "test.synthetic.editor", appName: "Synthetic Editor",
                                           style: .developer, instructions: "Synthetic instructions")]
            model.library.transforms = [.init(name: "Synthetic transform", instruction: "Synthetic instruction")]
            let expectedLibrary = model.library
            let expectedScratchpad = model.scratchpad

            // No debounce wait: shutdown must synchronously flush the latest edits.
            model.shutdown()
            #expect(model.errorMessage == nil)
            #expect(!model.isBusy)
            #expect(try permissions(store.root) == 0o700)
            #expect(try permissions(store.audioDirectory) == 0o700)
            for name in ["settings.json", "library.json", "history.json", "scratchpad.txt"] {
                #expect(try permissions(store.root.appendingPathComponent(name)) == 0o600)
            }
            #expect(try Data(contentsOf: store.root.appendingPathComponent("scratchpad.txt"))
                    == Data(expectedScratchpad.utf8))

            let reopened = AppModel(store: try AppStore(root: store.root), connectsToSystem: false)
            defer { reopened.shutdown() }
            #expect(reopened.scratchpad == expectedScratchpad)
            #expect(reopened.library.vocabulary == expectedLibrary.vocabulary)
            #expect(reopened.library.snippets == expectedLibrary.snippets)
            #expect(reopened.library.appRules == expectedLibrary.appRules)
            #expect(reopened.library.transforms == expectedLibrary.transforms)
            #expect(reopened.errorMessage == nil)

            reopened.scratchpad = ""
            reopened.library = LibraryData()
            reopened.shutdown()
            #expect(try store.loadScratchpad().isEmpty)
            #expect(try store.loadLibrary().vocabulary.isEmpty)
            #expect(try store.loadLibrary().snippets.isEmpty)
            #expect(try store.loadLibrary().appRules.isEmpty)
            #expect(try store.loadLibrary().transforms == CustomTransform.defaults)
            #expect(try permissions(store.root.appendingPathComponent("scratchpad.txt")) == 0o600)
            #expect(try permissions(store.root.appendingPathComponent("library.json")) == 0o600)
        }
    }

    @Test(arguments: [false, true])
    func disablingRetentionPersistsHistoryAndAudioRemovalWithoutClearingUnrelatedText(disableHistory: Bool) throws {
        try withStore { store in
            var settings = AppSettings()
            settings.retainAudio = true
            try store.saveSettings(settings)
            let entries: [HistoryEntry] = [
                .init(rawText: "Synthetic raw", text: "Synthetic retained text", audioFileName: "completed.m4a",
                      inserted: true, isCommand: true, originalText: "Synthetic original"),
                .init(rawText: "Synthetic failed raw", status: .failed, error: "Synthetic failure",
                      audioFileName: "failed.m4a")
            ]
            for name in ["completed.m4a", "failed.m4a"] {
                try Data("Synthetic audio".utf8).write(to: #require(store.audioURL(for: name)))
            }
            try store.saveHistory(entries)
            try store.saveScratchpad("Synthetic independent scratchpad")
            let model = AppModel(store: store, connectsToSystem: false)
            defer { model.shutdown() }
            #expect(model.history == entries)

            if disableHistory { model.settings.retainHistory = false }
            else { model.settings.retainAudio = false }

            let expected: [HistoryEntry] = disableHistory ? [] : entries.map {
                var entry = $0
                entry.audioFileName = nil
                return entry
            }
            #expect(model.history == expected)
            #expect(try store.loadHistory() == expected)
            #expect(try FileManager.default.contentsOfDirectory(atPath: store.audioDirectory.path).isEmpty)
            #expect(model.scratchpad == "Synthetic independent scratchpad")
            #expect(model.errorMessage == nil)
            model.shutdown()
            #expect(try store.loadSettings() == model.settings)

            let reopened = AppModel(store: try AppStore(root: store.root), connectsToSystem: false)
            defer { reopened.shutdown() }
            #expect(reopened.history == expected)
            #expect(reopened.settings.retainHistory == !disableHistory)
            #expect(reopened.settings.retainAudio == disableHistory)
            #expect(reopened.scratchpad == "Synthetic independent scratchpad")
            #expect(reopened.errorMessage == nil)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WHISPERTYPE_PREVIEW_PATH"] != nil,
                   "Opt-in windowless render; set WHISPERTYPE_PREVIEW_PATH to a temporary PNG path."))
    func mainViewRendersOffscreenAtDefaultAndMinimumSizes() throws {
        try withStore { store in
            let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["WHISPERTYPE_PREVIEW_PATH"]))
            _ = NSApplication.shared
            let model = AppModel(store: store, connectsToSystem: false)
            defer { model.shutdown() }
            model.showSetup = false

            for size in [NSSize(width: 1100, height: 740), NSSize(width: 860, height: 600)] {
                let view = NSHostingView(rootView: MainView().environmentObject(model))
                view.frame = NSRect(origin: .zero, size: size)
                view.layoutSubtreeIfNeeded()
                #expect(view.window == nil)
                #expect(view.bounds.size == size)
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                #expect(bitmap.pixelsWide >= Int(size.width))
                #expect(bitmap.pixelsHigh >= Int(size.height))
                #expect(png.count > 1_000)
                let destination = size.width == 1100 ? output : output.deletingPathExtension()
                    .appendingPathExtension("minimum.png")
                try png.write(to: destination, options: .atomic)
            }
            #expect(model.history.isEmpty)
            #expect(!model.isBusy)
            #expect(!model.showSetup)
            #expect(model.errorMessage == nil)
        }
    }
}
