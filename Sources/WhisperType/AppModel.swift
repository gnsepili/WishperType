import AppKit
import AVFoundation
import Combine
import SwiftUI
import UniformTypeIdentifiers
import WhisperCore

enum CapturePhase { case idle, requestingPermission, recording, stopping }

@MainActor
private final class CaptureSession {
    let id = UUID()
    let url: URL
    let target: InsertionTarget?
    let context: TextContext
    let settings: AppSettings
    let library: LibraryData
    let command: Bool
    let key: String
    let clipboardVersion: Int
    var startedAt = Date()
    var realtime: RealtimeTranscriber?
    var realtimeStart: Task<Void, Error>?
    var pcmContinuation: AsyncStream<Data>.Continuation?
    var pcmTask: Task<Void, Never>?

    init(url: URL, target: InsertionTarget?, context: TextContext, settings: AppSettings,
         library: LibraryData, command: Bool, key: String) {
        self.url = url; self.target = target; self.context = context; self.settings = settings
        self.library = library; self.command = command; self.key = key
        self.clipboardVersion = NSPasteboard.general.changeCount
    }

    func closeStream() { pcmContinuation?.finish(); pcmContinuation = nil }
    func cancelStream() {
        closeStream()
        realtimeStart?.cancel()
        pcmTask?.cancel()
        if let realtime { Task { await realtime.cancel() } }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings = AppSettings() { didSet { if loaded { settingsChanged(from: oldValue) } } }
    @Published var library = LibraryData() { didSet { scheduleSave() } }
    @Published var history: [HistoryEntry] = []
    @Published var phase: CapturePhase = .idle
    @Published var level: Float = 0
    @Published var elapsed: Double = 0
    @Published var liveTranscript = ""
    @Published var statusMessage = "Ready when you are."
    @Published var errorMessage: String?
    @Published var pendingCount = 0
    @Published var apiKeyDraft = ""
    @Published var hasAPIKey = false
    @Published var accessibilityGranted = false
    @Published var inputMonitoringGranted = false
    @Published var microphoneGranted = false
    @Published var hotkeysReady = false
    @Published var microphones: [MicrophoneDevice] = []
    @Published var scratchpad = "" { didSet { scheduleSave() } }
    @Published var isTransforming = false
    @Published var lastText = ""
    @Published var showSetup = false

    var isRecording: Bool { phase == .recording }
    var isBusy: Bool { phase != .idle || pendingCount > 0 || isTransforming }
    var totalWords: Int { history.filter { $0.status == .completed }.reduce(0) { $0 + $1.wordCount } }
    var totalAudioMinutes: Double { history.reduce(0) { $0 + $1.duration } / 60 }
    var averageLatency: Double {
        let values = history.filter { $0.status == .completed && $0.duration > 0 }.map(\.latency)
        return values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
    var onShowMainWindow: (() -> Void)?
    private var overlay: RecordingOverlayController?
    private let recorder = AudioRecorder()
    private let insertion = TextInsertionService()
    private let hotkeys = HotkeyManager()
    private var store: AppStore?
    private var apiKey = ""
    private var capture: CaptureSession?
    private var permissionTask: Task<Void, Never>?
    private var clock: Task<Void, Never>?
    private var hideOverlayTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var transformTask: Task<Void, Never>?
    private var queueTail: Task<Void, Never>?
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var jobSessions: [UUID: CaptureSession] = [:]
    private var retryJobs: [UUID: UUID] = [:]
    private var player: AVAudioPlayer?
    private var lastVoiceAt = Date()
    private var loaded = false
    private var writableFiles: Set<String> = []
    private var observers: [NSObjectProtocol] = []
    private var privacyEpoch = UUID()

    init(store suppliedStore: AppStore? = nil, connectsToSystem: Bool = true) {
        do {
            let store = try suppliedStore ?? AppStore()
            self.store = store
            do { settings = try store.loadSettings(); writableFiles.insert("settings") }
            catch { errorMessage = "Settings could not be read. The original file is preserved: \(error.localizedDescription)" }
            do { library = try store.loadLibrary(); writableFiles.insert("library") }
            catch { errorMessage = "Your library could not be read. The original file is preserved: \(error.localizedDescription)" }
            do { history = try store.loadHistory(); writableFiles.insert("history") }
            catch { errorMessage = "History could not be read. The original file is preserved: \(error.localizedDescription)" }
            do { scratchpad = try store.loadScratchpad(); writableFiles.insert("scratchpad") }
            catch { errorMessage = "Scratchpad could not be read. The original file is preserved: \(error.localizedDescription)" }
            if writableFiles.contains("history"), writableFiles.contains("settings") {
                history = try store.prune(history: history, settings: settings)
                try store.saveHistory(history)
            }
        } catch { errorMessage = "Local storage is unavailable: \(error.localizedDescription)" }
        if connectsToSystem {
            do { apiKey = try KeychainStore.loadAPIKey() ?? "" }
            catch { errorMessage = "Keychain: \(error.localizedDescription)" }
        }
        hasAPIKey = !apiKey.isEmpty
        lastText = history.first(where: { $0.status == .completed })?.text ?? ""
        loaded = true
        showSetup = !hasAPIKey
        recorder.onLevel = { [weak self] level in
            guard let self else { return }
            self.level = level
            if level > 0.12 { self.lastVoiceAt = Date() }
        }
        recorder.onFailure = { [weak self] message in
            guard let self else { return }
            self.errorMessage = message
            // The recorder closes its file before reporting a device failure.
            if self.phase == .recording { self.stopRecording() }
        }
        hotkeys.onAction = { [weak self] action in self?.handle(action) }
        guard connectsToSystem else { return }
        refreshPermissions(); refreshMicrophones()
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refreshPermissions() } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.cancelRecording() } })
    }

    func installOverlay() { if overlay == nil { overlay = RecordingOverlayController(model: self) } }
    func showMainWindow() { onShowMainWindow?() }
    func dismissError() { errorMessage = nil }

    private func handle(_ action: HotkeyAction) {
        switch action {
        case .beginDictation: startRecording()
        case .endDictation, .endCommand: stopRecording()
        case .toggleDictation: toggleRecording()
        case .beginCommand: startRecording(command: true)
        case .cancel:
            if phase != .idle { cancelRecording() } else { cancelPending() }
        case .cancelForCommandUpgrade: cancelCapture(resetShortcut: false)
        case .copyLast: copyLast()
        case .pasteLast: pasteLast()
        case .transformSelection:
            if let transform = library.transforms.first { runTransform(transform) }
        }
    }

    func toggleRecording() {
        if phase == .recording { stopRecording() }
        else if phase == .idle { startRecording() }
    }

    func startRecording(command: Bool = false) {
        guard phase == .idle else { return }
        guard !isTransforming, settings.pipelineEnabled || pendingCount == 0 else {
            statusMessage = "Wait for the current result, or enable background dictation in Settings."
            return
        }
        guard pendingCount < 8 else { errorMessage = "Eight dictations are already queued. Wait for a result before recording again."; return }
        guard hasAPIKey else { showSetup = true; showMainWindow(); return }
        guard let store else { errorMessage = "Recording requires writable local application storage."; return }
        let target = insertion.captureTarget(includeContext: settings.contextEnabled)
        guard !target.isSecure else { errorMessage = "Dictation is disabled in password fields and while Secure Input is active."; return }
        if command && target.context.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorMessage = "Select text in another app first, then hold Control + Option + Command and speak your edit."
            return
        }
        let snapshot = resolvedSettings(for: target.context)
        let session = CaptureSession(url: store.newRecordingURL(), target: target, context: target.context,
                                     settings: snapshot, library: library, command: command, key: apiKey)
        capture = session
        phase = .requestingPermission
        hotkeys.isActive = true
        permissionTask = Task { [weak self] in
            guard let self else { return }
            let granted = await AudioRecorder.requestPermission()
            guard !Task.isCancelled, self.capture?.id == session.id else { return }
            self.microphoneGranted = granted
            guard granted else {
                self.capture = nil; self.phase = .idle; self.updateHotkeyState()
                self.errorMessage = "Microphone access is required. Enable WhisperType in System Settings > Privacy & Security > Microphone."
                return
            }
            guard !self.insertion.captureTarget(includeContext: false).isSecure else {
                self.capture = nil; self.phase = .idle; self.updateHotkeyState()
                self.errorMessage = "Recording was not started because Secure Input is active."
                return
            }
            do {
                self.configureRealtime(session)
                try self.recorder.start(at: session.url, deviceID: snapshot.microphoneID)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: session.url.path)
                session.startedAt = Date()
                self.lastVoiceAt = Date()
                self.phase = .recording; self.elapsed = 0; self.level = 0; self.liveTranscript = ""
                self.statusMessage = command ? "Speak an instruction for the selected text." : "Listening. Release the shortcut or press Stop."
                self.hideOverlayTask?.cancel(); self.overlay?.show()
                self.playSound("Tink")
                self.startClock(session)
            } catch {
                self.recorder.cancel(); session.cancelStream(); self.capture = nil
                self.phase = .idle; self.updateHotkeyState(); self.errorMessage = error.localizedDescription
            }
        }
    }

    private func configureRealtime(_ session: CaptureSession) {
        recorder.onPCM = nil
        guard session.settings.processingMode == .live else { return }
        let sessionID = session.id
        let realtime = RealtimeTranscriber(apiKey: session.key, model: session.settings.realtimeModel,
            language: session.settings.language, vocabulary: session.library.vocabulary) { [weak self] text in
                Task { @MainActor in
                    guard self?.capture?.id == sessionID else { return }
                    self?.liveTranscript = text
                }
            }
        session.realtime = realtime
        let stream = AsyncStream<Data>(bufferingPolicy: .bufferingOldest(512)) { continuation in
            session.pcmContinuation = continuation
        }
        let continuation = session.pcmContinuation!
        recorder.onPCM = { data in
            if case .dropped = continuation.yield(data) {
                continuation.finish()
                Task { await realtime.cancel() }
            }
        }
        // One consumer preserves capture order and drains before the turn is committed.
        session.pcmTask = Task {
            do { for await data in stream { try await realtime.append(data) } }
            catch { await realtime.cancel() }
        }
        session.realtimeStart = Task { try await realtime.start() }
    }

    private func startClock(_ session: CaptureSession) {
        clock?.cancel()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, self.capture?.id == session.id, self.phase == .recording else { return }
                self.elapsed = Date().timeIntervalSince(session.startedAt)
                let maxDuration = min(max(session.settings.maxRecordingSeconds, 10), 1200)
                if self.elapsed >= maxDuration {
                    self.stopRecording(); self.statusMessage = "Recording limit reached. Processing your dictation."; return
                }
                if session.settings.silenceAutoStop, self.elapsed > 2,
                   Date().timeIntervalSince(self.lastVoiceAt) >= max(3, session.settings.silenceSeconds) {
                    self.stopRecording(); return
                }
            }
        }
    }

    func stopRecording() {
        if phase == .requestingPermission { cancelRecording(); return }
        guard phase == .recording, let session = capture else { return }
        phase = .stopping
        clock?.cancel()
        let recording = recorder.stop() ?? AudioRecording(url: session.url, duration: elapsed, hasSpeech: true)
        recorder.onPCM = nil
        session.closeStream()
        capture = nil; phase = .idle; level = 0
        hotkeys.resetCaptureState()
        playSound("Pop")
        guard recording.duration >= 0.2, recording.hasSpeech else {
            session.cancelStream(); removeAudio(session.url)
            statusMessage = "No speech detected. Try again closer to the microphone."
            updateHotkeyState(); hideOverlaySoon(); return
        }
        enqueue(session, recording: recording)
    }

    func cancelRecording() {
        cancelCapture(resetShortcut: true)
    }

    private func cancelCapture(resetShortcut: Bool) {
        permissionTask?.cancel(); permissionTask = nil
        clock?.cancel()
        recorder.cancel(); recorder.onPCM = nil
        if let capture { capture.cancelStream(); removeAudio(capture.url) }
        capture = nil; phase = .idle; level = 0; liveTranscript = ""
        if resetShortcut { hotkeys.resetCaptureState() }
        statusMessage = "Recording cancelled."
        updateHotkeyState(); hideOverlaySoon()
    }

    private func enqueue(_ session: CaptureSession, recording: AudioRecording, replacing: UUID? = nil) {
        let previous = queueTail
        let queuedAt = Date()
        let epoch = privacyEpoch
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer {
                self.jobs[session.id] = nil; self.pendingCount = self.jobs.count
                self.jobSessions[session.id] = nil
                if let replacing, self.retryJobs[replacing] == session.id { self.retryJobs[replacing] = nil }
                self.updateHotkeyState(); self.hideOverlaySoon()
            }
            guard !Task.isCancelled else { session.cancelStream(); self.removeAudio(recording.url); return }
            if !self.isRecording { self.statusMessage = "Transcribing with OpenAI..." }
            var raw = ""
            do {
                let client = OpenAIClient(apiKey: session.key)
                if let realtime = session.realtime {
                    do {
                        try await session.realtimeStart?.value
                        await session.pcmTask?.value
                        raw = try await realtime.finish()
                    } catch {
                        try Task.checkCancellation()
                        await realtime.cancel()
                        if !self.isRecording { self.statusMessage = "Live connection unavailable. Transcribing the saved recording..." }
                        raw = try await client.transcribe(fileURL: recording.url, settings: session.settings, vocabulary: session.library.vocabulary)
                    }
                } else {
                    raw = try await client.transcribe(fileURL: recording.url, settings: session.settings, vocabulary: session.library.vocabulary)
                }
                try Task.checkCancellation()
                var text = raw
                var warning: String?
                if session.command || TextProcessing.needsRewrite(settings: session.settings) {
                    if !self.isRecording { self.statusMessage = session.command ? "Editing selected text..." : "Applying your writing preferences..." }
                    do {
                        text = try await client.rewrite(.init(text: raw, settings: session.settings, context: session.context,
                                                              instruction: session.command ? raw : nil))
                    } catch {
                        try Task.checkCancellation()
                        if session.command { throw error }
                        warning = "Cleanup failed; the original transcription is available. \(error.localizedDescription)"
                    }
                }
                // Expand only after model editing, so saved snippets never get paraphrased.
                if !session.command { text = TextProcessing.apply(text, vocabulary: session.library.vocabulary, snippets: session.library.snippets) }
                try Task.checkCancellation()
                self.lastText = text
                var inserted = false
                if session.settings.autoInsert, !self.isRecording, let target = session.target {
                    inserted = await self.insertion.insert(text, into: target, restoreClipboard: session.settings.restoreClipboard)
                }
                try Task.checkCancellation()
                let copied = !inserted && NSPasteboard.general.changeCount == session.clipboardVersion
                if copied { self.insertion.copy(text) }
                let keptAudio = self.shouldKeepAudio(session: session, epoch: epoch)
                let entry = HistoryEntry(id: replacing ?? session.id, createdAt: session.startedAt, duration: recording.duration,
                    targetApp: session.context.appName, bundleID: session.context.bundleID, rawText: raw, text: text,
                    error: warning, audioFileName: keptAudio ? recording.url.lastPathComponent : nil,
                    latency: Date().timeIntervalSince(queuedAt), inserted: inserted, isCommand: session.command,
                    originalText: session.command ? session.context.selectedText : nil)
                if self.settings.retainHistory, epoch == self.privacyEpoch { self.saveEntry(entry) }
                if !keptAudio { self.removeAudio(recording.url) }
                if !self.isRecording {
                    self.statusMessage = inserted ? "Inserted into \(session.context.appName)." :
                        (copied ? "Copied. Paste with Command + V." : "Result ready. Clipboard preserved; use Copy Last or History to retrieve it.")
                }
                if let warning { self.errorMessage = warning }
            } catch {
                session.cancelStream()
                if Task.isCancelled || error is CancellationError { self.removeAudio(recording.url); return }
                let keptAudio = self.shouldKeepAudio(session: session, epoch: epoch)
                let message = error.localizedDescription
                let entry = HistoryEntry(id: replacing ?? session.id, createdAt: session.startedAt, duration: recording.duration,
                    targetApp: session.context.appName, bundleID: session.context.bundleID, rawText: raw,
                    status: .failed, error: message, audioFileName: keptAudio ? recording.url.lastPathComponent : nil,
                    latency: Date().timeIntervalSince(queuedAt), isCommand: session.command,
                    originalText: session.command ? session.context.selectedText : nil)
                if self.settings.retainHistory, epoch == self.privacyEpoch { self.saveEntry(entry) }
                if !keptAudio { self.removeAudio(recording.url) }
                self.errorMessage = message + (keptAudio ? " Retry this recording in History." : " Audio was not retained. Enable audio retention before recording if you want retries.")
                if !self.isRecording { self.statusMessage = "Transcription failed." }
            }
        }
        jobs[session.id] = task; jobSessions[session.id] = session
        if let replacing { retryJobs[replacing] = session.id }
        queueTail = task; pendingCount = jobs.count
        statusMessage = pendingCount > 1 ? "\(pendingCount) dictations queued." : "Transcribing with OpenAI..."
        updateHotkeyState(); hideOverlayTask?.cancel(); overlay?.show()
    }

    private func shouldKeepAudio(session: CaptureSession, epoch: UUID) -> Bool {
        settings.retainHistory && settings.retainAudio && session.settings.retainAudio && epoch == privacyEpoch
    }

    func cancelPending() {
        for task in jobs.values { task.cancel() }
        for session in jobSessions.values { session.cancelStream() }
        transformTask?.cancel()
        statusMessage = "Pending work cancelled."
    }

    private func resolvedSettings(for context: TextContext) -> AppSettings {
        var result = settings
        if let rule = library.appRules.first(where: { $0.bundleID == context.bundleID }) {
            result.style = rule.style
            if !rule.instructions.isEmpty { result.customInstructions += "\n" + rule.instructions }
        }
        return result
    }

    func copyText(_ text: String) { insertion.copy(text); statusMessage = "Copied to clipboard." }
    func copyLast() { if !lastText.isEmpty { copyText(lastText) } }
    func pasteLast() {
        guard !lastText.isEmpty else { return }
        let text = lastText
        let clipboardVersion = NSPasteboard.general.changeCount
        Task {
            let inserted = await insertion.pasteIntoCurrentApp(text, restoreClipboard: settings.restoreClipboard)
            let copied = !inserted && NSPasteboard.general.changeCount == clipboardVersion
            if copied { insertion.copy(text) }
            statusMessage = inserted ? "Last dictation inserted." : (copied ? "Copied. Press Command + V in your destination app." : "Clipboard preserved. Use Copy Last to retrieve the result.")
        }
    }

    func runTransform(_ transform: CustomTransform) {
        guard hasAPIKey, !isTransforming, phase == .idle else { return }
        let target = insertion.captureTarget(includeContext: settings.contextEnabled)
        guard !target.isSecure, !target.context.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Select text in another app, then press Control + Option + P to apply your first transform."
            return
        }
        guard target.context.selectedText.count <= 50_000 else { errorMessage = "Select less than 50,000 characters for a transform."; return }
        performTransform(transform, text: target.context.selectedText, target: target)
    }

    func transformScratchpad(_ transform: CustomTransform) {
        guard hasAPIKey, !isTransforming, !scratchpad.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard scratchpad.count <= 100_000 else { errorMessage = "Use less than 100,000 characters for a Scratchpad transform."; return }
        performTransform(transform, text: scratchpad, target: nil)
    }

    private func performTransform(_ transform: CustomTransform, text: String, target: InsertionTarget?) {
        isTransforming = true; updateHotkeyState()
        let context = target?.context ?? TextContext(appName: "Scratchpad", selectedText: text)
        let snapshot = resolvedSettings(for: context)
        let key = apiKey
        let epoch = privacyEpoch
        let clipboardVersion = NSPasteboard.general.changeCount
        statusMessage = "Running \(transform.name)..."
        transformTask = Task {
            defer { isTransforming = false; updateHotkeyState() }
            do {
                let output = try await OpenAIClient(apiKey: key).rewrite(.init(text: text, settings: snapshot,
                                                                              context: context, instruction: transform.instruction))
                try Task.checkCancellation()
                var inserted = false
                if let target {
                    if snapshot.autoInsert { inserted = await insertion.insert(output, into: target, restoreClipboard: snapshot.restoreClipboard) }
                    try Task.checkCancellation()
                    if !inserted, NSPasteboard.general.changeCount == clipboardVersion { insertion.copy(output) }
                } else if scratchpad == text {
                    scratchpad = output
                } else {
                    if NSPasteboard.general.changeCount == clipboardVersion { insertion.copy(output) }
                    errorMessage = "Scratchpad changed while the transform was running. Your edits were preserved; retrieve the result using Copy Last."
                }
                lastText = output
                if settings.retainHistory, epoch == privacyEpoch {
                    saveEntry(.init(targetApp: context.appName, bundleID: context.bundleID, rawText: text, text: output,
                                    inserted: inserted, isCommand: true, originalText: text))
                }
                statusMessage = target == nil ? "Transform complete. Original saved in History when enabled." : (inserted ? "Selection updated." : "Transform ready. Use Copy Last to retrieve it.")
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }

    func retry(_ entry: HistoryEntry) {
        guard hasAPIKey, let file = entry.audioFileName, let url = store?.audioURL(for: file),
              FileManager.default.fileExists(atPath: url.path) else { errorMessage = "No retained audio is available for this entry."; return }
        guard pendingCount < 8, retryJobs[entry.id] == nil else { return }
        var snapshot = settings; snapshot.autoInsert = false; snapshot.processingMode = .accurate
        // Each job owns its audio file, so deletion/cancellation cannot race another retry.
        guard let copied = store?.newRecordingURL() else { return }
        do { try FileManager.default.copyItem(at: url, to: copied) }
        catch { errorMessage = error.localizedDescription; return }
        let context = TextContext(appName: entry.targetApp, bundleID: entry.bundleID, selectedText: entry.originalText ?? "")
        let session = CaptureSession(url: copied, target: nil, context: context, settings: snapshot,
                                     library: library, command: entry.isCommand, key: apiKey)
        enqueue(session, recording: .init(url: copied, duration: entry.duration, hasSpeech: true), replacing: entry.id)
    }

    func useRawText(_ entry: HistoryEntry) {
        guard let index = history.firstIndex(where: { $0.id == entry.id }) else { return }
        history[index].text = entry.isCommand ? (entry.originalText ?? entry.rawText) : entry.rawText
        history[index].inserted = false
        lastText = history[index].text
        copyText(lastText); persistHistory()
    }

    private func saveEntry(_ entry: HistoryEntry) {
        if let old = history.first(where: { $0.id == entry.id }), old.audioFileName != entry.audioFileName,
           let name = old.audioFileName { try? store?.deleteAudio(fileName: name) }
        history.removeAll { $0.id == entry.id }; history.insert(entry, at: 0)
        persistHistory()
    }

    private func persistHistory() {
        guard writableFiles.contains("history"), writableFiles.contains("settings"), let store else { return }
        do { history = try store.prune(history: history, settings: settings); try store.saveHistory(history) }
        catch { errorMessage = "Could not update history: \(error.localizedDescription)" }
    }

    func deleteHistory(_ entry: HistoryEntry) {
        stopPlayback()
        if let jobID = retryJobs[entry.id] {
            jobs[jobID]?.cancel(); jobSessions[jobID]?.cancelStream()
        }
        if let file = entry.audioFileName { do { try store?.deleteAudio(fileName: file) } catch { errorMessage = error.localizedDescription; return } }
        history.removeAll { $0.id == entry.id }; persistHistory()
    }

    func clearHistory() {
        privacyEpoch = UUID()
        cancelPending(); stopPlayback()
        for entry in history {
            if let file = entry.audioFileName { do { try store?.deleteAudio(fileName: file) } catch { errorMessage = error.localizedDescription } }
        }
        history = []; lastText = ""; persistHistory()
    }

    func playAudio(_ entry: HistoryEntry) {
        guard let file = entry.audioFileName, let url = store?.audioURL(for: file) else { return }
        do { player?.stop(); player = try AVAudioPlayer(contentsOf: url); player?.play() }
        catch { errorMessage = error.localizedDescription }
    }
    func stopPlayback() { player?.stop(); player = nil }

    func saveAPIKey() {
        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-"), key.count > 15, !key.contains(where: { $0.isWhitespace }) else {
            errorMessage = "Enter an OpenAI API key beginning with sk-. A ChatGPT subscription is not an API key."
            return
        }
        do {
            try KeychainStore.saveAPIKey(key); apiKey = key; hasAPIKey = true; apiKeyDraft = ""
            statusMessage = "API key saved in Keychain. The first transcription will verify access."
        } catch { errorMessage = "Could not save API key: \(error.localizedDescription)" }
    }

    func removeAPIKey() {
        cancelRecording(); cancelPending()
        do { try KeychainStore.deleteAPIKey(); apiKey = ""; hasAPIKey = false; apiKeyDraft = "" }
        catch { errorMessage = error.localizedDescription }
    }

    func refreshPermissions() {
        accessibilityGranted = SystemPermissions.accessibilityGranted
        inputMonitoringGranted = SystemPermissions.inputMonitoringGranted
        microphoneGranted = recorder.permissionGranted
        if phase == .idle { hotkeysReady = hotkeys.start(preset: settings.shortcut); updateHotkeyState() }
    }
    func refreshMicrophones() { microphones = AudioRecorder.microphones() }
    func requestAccessibilityPermission() { insertion.requestAccessibility(); SystemPermissions.openAccessibilitySettings() }
    func requestInputMonitoringPermission() { _ = SystemPermissions.requestInputMonitoring(); SystemPermissions.openInputMonitoringSettings() }
    func requestMicrophonePermission() {
        Task {
            microphoneGranted = await AudioRecorder.requestPermission()
            if !microphoneGranted {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
        }
    }
    func applySettings() { refreshPermissions(); scheduleSave() }
    private func updateHotkeyState() { hotkeys.isActive = phase != .idle || pendingCount > 0 || isTransforming }

    private func settingsChanged(from old: AppSettings) {
        if settings.shortcut != old.shortcut, phase == .idle { refreshPermissions() }
        if settings.launchAtLogin != old.launchAtLogin {
            do { try LoginItemService.setEnabled(settings.launchAtLogin) }
            catch { errorMessage = "Launch at login: \(error.localizedDescription)" }
        }
        if settings.retainHistory != old.retainHistory || settings.retainAudio != old.retainAudio || settings.retentionDays != old.retentionDays {
            if !settings.retainHistory || !settings.retainAudio { privacyEpoch = UUID() }
            persistHistory()
        }
        scheduleSave()
    }

    private func scheduleSave() {
        guard loaded else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.saveAll()
        }
    }
    private func saveAll() {
        guard let store else { return }
        do {
            if writableFiles.contains("settings") { try store.saveSettings(settings) }
            if writableFiles.contains("library") { try store.saveLibrary(library) }
            if writableFiles.contains("scratchpad") { try store.saveScratchpad(scratchpad) }
        } catch { errorMessage = "Could not save changes: \(error.localizedDescription)" }
    }

    func importLibrary() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 5_000_000 else { throw CocoaError(.fileReadTooLarge) }
            let imported = try JSONDecoder().decode(LibraryData.self, from: Data(contentsOf: url))
            guard imported.vocabulary.count + imported.snippets.count + imported.appRules.count + imported.transforms.count <= 10_000 else {
                errorMessage = "Import is limited to 10,000 entries."; return
            }
            for item in imported.vocabulary where !library.vocabulary.contains(where: { $0.term.caseInsensitiveCompare(item.term) == .orderedSame }) {
                library.vocabulary.append(.init(term: item.term, heardAs: item.heardAs))
            }
            for item in imported.snippets where !library.snippets.contains(where: { $0.trigger.caseInsensitiveCompare(item.trigger) == .orderedSame }) {
                library.snippets.append(.init(trigger: item.trigger, expansion: item.expansion))
            }
            for item in imported.appRules where !library.appRules.contains(where: { $0.bundleID == item.bundleID }) {
                library.appRules.append(.init(bundleID: item.bundleID, appName: item.appName, style: item.style, instructions: item.instructions))
            }
            for item in imported.transforms where !library.transforms.contains(where: { $0.name == item.name }) {
                library.transforms.append(.init(name: item.name, instruction: item.instruction))
            }
            statusMessage = "Library imported. Existing matching entries were kept."
        } catch { errorMessage = "Could not import a WhisperType library: \(error.localizedDescription)" }
    }

    func exportLibrary() { exportJSON(library, filename: "WhisperType-library.json") }
    func exportHistory() { exportJSON(history, filename: "WhisperType-history.json") }
    private func exportJSON<T: Encodable>(_ value: T, filename: String) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = filename
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { errorMessage = error.localizedDescription }
    }

    func importAudio() {
        guard hasAPIKey, pendingCount < 8, let store else { showSetup = !hasAPIKey; return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio, .movie]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 25 * 1024 * 1024 else { errorMessage = "Choose a supported audio file smaller than 25 MB."; return }
            let allowed = ["m4a", "mp3", "mp4", "wav", "webm", "mpeg", "mpga", "flac", "ogg"]
            let ext = source.pathExtension.lowercased()
            guard allowed.contains(ext) else { errorMessage = "Choose M4A, MP3, MP4, WAV, WebM, MPEG, FLAC, or OGG audio."; return }
            let url = store.audioDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
            try FileManager.default.copyItem(at: source, to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            var snapshot = settings; snapshot.autoInsert = false; snapshot.processingMode = .accurate
            let session = CaptureSession(url: url, target: nil, context: .init(appName: "Imported audio"),
                                         settings: snapshot, library: library, command: false, key: apiKey)
            let duration = (try? AVAudioPlayer(contentsOf: url).duration) ?? 0
            enqueue(session, recording: .init(url: url, duration: duration, hasSpeech: true))
        } catch { errorMessage = error.localizedDescription }
    }

    func openDataFolder() { if let store { NSWorkspace.shared.open(store.root) } }
    private func removeAudio(_ url: URL) {
        do { try store?.deleteAudio(fileName: url.lastPathComponent) }
        catch { errorMessage = "Could not delete temporary audio: \(error.localizedDescription)" }
    }
    private func playSound(_ name: String) { if settings.soundEffects { NSSound(named: name)?.play() } }
    private func hideOverlaySoon() {
        guard phase == .idle, pendingCount == 0 else { return }
        hideOverlayTask?.cancel()
        hideOverlayTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, self.phase == .idle, self.pendingCount == 0 else { return }
            self.overlay?.hide()
        }
    }

    func shutdown() {
        cancelRecording(); cancelPending(); hotkeys.stop(); stopPlayback()
        // Termination does not wait for cancelled Tasks to run their cleanup.
        for session in jobSessions.values { removeAudio(session.url) }
        saveTask?.cancel(); saveAll(); overlay?.hide()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers = []
    }
}
