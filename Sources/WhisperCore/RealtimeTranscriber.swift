import Foundation

/// A single recording/turn. Append may buffer audio before start finishes; finish
/// drains that buffer before committing. Any failure makes this instance terminal.
public actor RealtimeTranscriber {
    private enum State { case idle, connecting, ready, finished, failed }
    private struct Failure: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    private let apiKey: String
    private let model: String
    private let language: String
    private let vocabulary: [VocabularyEntry]
    private let onDelta: @Sendable (String) -> Void
    private var state: State = .idle
    private var terminalError: Error?
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var configurationTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var startTimer: Task<Void, Never>?
    private var finishTimer: Task<Void, Never>?
    private var startWaiter: CheckedContinuation<Void, Error>?
    private var finishWaiter: CheckedContinuation<String, Error>?
    private var configurationSent = false
    private var configurationAcknowledged = false
    private var finishing = false
    private var commitStarted = false
    private var commitSent = false
    private var commitAcknowledged = false
    private var itemID: String?
    private var preview = ""
    private var transcript: String?
    private var pendingPCM: [Data] = []
    private var pendingIndex = 0
    private var pendingBytes = 0
    private var totalBytes = 0
    private var signalSamples = 0

    // Includes the in-flight send: about 21 seconds of mono PCM16 at 24 kHz.
    private let maximumPendingBytes = 1_048_576

    public init(apiKey: String, model: String, language: String,
                vocabulary: [VocabularyEntry], onDelta: @escaping @Sendable (String) -> Void) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = language.trimmingCharacters(in: .whitespacesAndNewlines)
        self.vocabulary = vocabulary
        self.onDelta = onDelta
    }

    public func start() async throws {
        try await withTaskCancellationHandler {
            guard let update = try prepareStart() else { return }
            var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 12
            let session = URLSession(configuration: .ephemeral)
            let socket = session.webSocketTask(with: request)
            self.session = session
            self.socket = socket

            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                startWaiter = waiter
                startTimer = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 12_000_000_000) }
                    catch { return }
                    await self?.fail(Failure(message: "Realtime transcription did not become ready within 12 seconds."))
                }
                socket.resume()
                receiveTask = Task { [weak self] in
                    do {
                        while !Task.isCancelled {
                            let message = try await socket.receive()
                            guard let self, await self.receive(message) else { return }
                        }
                    } catch {
                        await self?.fail(error)
                    }
                }
                configurationTask = Task { [weak self] in
                    do {
                        try await socket.send(.string(update))
                        await self?.didSendConfiguration()
                    } catch {
                        await self?.fail(error)
                    }
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    /// Accepts PCM16 little-endian, mono, 24 kHz. Returns once queued, not once
    /// transmitted. Delivery errors are also surfaced by start/finish or the next append.
    public func append(_ pcm: Data) async throws {
        if Task.isCancelled {
            fail(CancellationError())
            throw CancellationError()
        }
        if let terminalError { throw terminalError }
        guard !finishing, state == .idle || state == .connecting || state == .ready else {
            throw Failure(message: "Audio cannot be appended after realtime transcription finishes.")
        }
        guard !pcm.isEmpty else { return }
        guard pcm.count.isMultiple(of: 2) else {
            let error = Failure(message: "Realtime audio must contain complete PCM16 samples.")
            fail(error)
            throw error
        }
        guard pcm.count <= maximumPendingBytes - pendingBytes else {
            let error = Failure(message: "Realtime audio buffering exceeded its limit. Use file transcription instead.")
            fail(error)
            throw error
        }
        // Only reject effectively silent input, not quiet speech or pauses.
        pcm.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for index in stride(from: 0, to: bytes.count, by: 2) {
                let sample = Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
                if abs(Int(sample)) > 3 { signalSamples += 1 }
            }
        }
        totalBytes += pcm.count
        pendingBytes += pcm.count
        pendingPCM.append(pcm)
        beginSending()
    }

    public func finish() async throws -> String {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if let terminalError { throw terminalError }
            if state == .finished, let transcript { return transcript }
            guard state == .connecting || state == .ready else {
                throw Failure(message: "Start realtime transcription before finishing it.")
            }
            guard !finishing else {
                throw Failure(message: "Realtime transcription is already finishing.")
            }
            guard totalBytes >= 4_800, signalSamples >= 240 else {
                let error = Failure(message: "The recording is silent or shorter than 100 milliseconds.")
                fail(error)
                throw error
            }
            finishing = true
            let result = try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<String, Error>) in
                finishWaiter = waiter
                finishTimer = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 45_000_000_000) }
                    catch { return }
                    await self?.fail(Failure(message: "Realtime transcription did not finish within 45 seconds."))
                }
                beginSending()
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    public func cancel() async {
        fail(CancellationError())
    }

    // Separates local validation/state transitions from opening the WebSocket.
    func prepareStart() throws -> String? {
        if Task.isCancelled {
            let error = CancellationError()
            fail(error)
            throw error
        }
        if let terminalError { throw terminalError }
        if state == .ready { return nil }
        guard state == .idle else {
            throw Failure(message: "The realtime session has already been started.")
        }
        do {
            guard !apiKey.isEmpty, !model.isEmpty else {
                throw Failure(message: "A realtime API key and transcription model are required.")
            }
            let update = try sessionUpdate()
            state = .connecting
            return update
        } catch {
            fail(error)
            throw error
        }
    }

    private func sessionUpdate() throws -> String {
        var transcription: [String: Any] = ["model": model]
        let isLiveModel = model == "gpt-live-transcribe" || model.hasPrefix("gpt-live-transcribe-")
        let isNewModel = isLiveModel
            || model == "gpt-transcribe" || model.hasPrefix("gpt-transcribe-")
        let explicitLanguage = !language.isEmpty && language.lowercased() != "auto"
        var seen = Set<String>()
        var terms: [String] = []
        let invalidKeywordCharacters = CharacterSet(charactersIn: "<>\r\n")
        for entry in vocabulary {
            let term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, term.count <= 120 else { continue }
            // One invalid keyword rejects the entire session, including otherwise valid speech.
            if isNewModel, term.rangeOfCharacter(from: invalidKeywordCharacters) != nil { continue }
            guard seen.insert(term).inserted else { continue }
            terms.append(term)
            if terms.count == 100 { break }
        }
        if isNewModel {
            if explicitLanguage { transcription["languages"] = [language] }
            if !terms.isEmpty { transcription["keywords"] = terms }
            if isLiveModel { transcription["delay"] = "medium" }
        } else {
            if explicitLanguage { transcription["language"] = language }
            if !terms.isEmpty { transcription["prompt"] = String(terms.joined(separator: ", ").prefix(1_200)) }
        }
        return try encode([
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": ["input": [
                    "format": ["type": "audio/pcm", "rate": 24_000],
                    "transcription": transcription,
                    "turn_detection": NSNull(),
                    "noise_reduction": ["type": "near_field"]
                ]]
            ]
        ])
    }

    private func encode(_ event: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: event)
        return String(decoding: data, as: UTF8.self)
    }

    func didSendConfiguration() {
        configurationSent = true
        becomeReady()
    }

    private func becomeReady() {
        guard state == .connecting, configurationSent, configurationAcknowledged else { return }
        state = .ready
        startTimer?.cancel()
        startTimer = nil
        let waiter = startWaiter
        startWaiter = nil
        waiter?.resume()
        beginSending()
    }

    private func beginSending() {
        guard state == .ready, sendTask == nil,
              pendingIndex < pendingPCM.count || (finishing && !commitStarted) else { return }
        sendTask = Task { [weak self] in await self?.sendPendingAudio() }
    }

    private func sendPendingAudio() async {
        guard let socket else { return }
        do {
            while state == .ready && !Task.isCancelled {
                if pendingIndex < pendingPCM.count {
                    let pcm = pendingPCM[pendingIndex]
                    pendingPCM[pendingIndex] = Data()
                    pendingIndex += 1
                    let event = try encode(["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()])
                    try await socket.send(.string(event))
                    guard state == .ready else { return }
                    pendingBytes -= pcm.count
                    if pendingIndex == pendingPCM.count {
                        pendingPCM.removeAll(keepingCapacity: true)
                        pendingIndex = 0
                    } else if pendingIndex >= 128 {
                        pendingPCM.removeFirst(pendingIndex)
                        pendingIndex = 0
                    }
                } else if finishing && !commitStarted {
                    commitStarted = true
                    try await socket.send(.string(try encode(["type": "input_audio_buffer.commit"])))
                    guard state == .ready else { return }
                    commitSent = true
                    completeIfReady()
                    break
                } else {
                    break
                }
            }
            sendTask = nil
        } catch {
            fail(error)
        }
    }

    func receive(_ message: URLSessionWebSocketTask.Message) -> Bool {
        guard state == .connecting || state == .ready else { return false }
        do {
            let data: Data
            switch message {
            case .string(let text): data = Data(text.utf8)
            case .data(let bytes): data = bytes
            @unknown default: throw Failure(message: "Unsupported realtime WebSocket message.")
            }
            guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else {
                throw Failure(message: "Invalid realtime transcription event.")
            }
            switch type {
            case "session.updated":
                configurationAcknowledged = true
                becomeReady()
            case "input_audio_buffer.committed":
                try acceptItem(event, requiresCommit: true)
                commitAcknowledged = true
                completeIfReady()
            case "conversation.item.input_audio_transcription.delta":
                try acceptItem(event)
                if let delta = event["delta"] as? String, !delta.isEmpty {
                    preview += delta
                    onDelta(preview)
                }
            case "conversation.item.input_audio_transcription.completed":
                try acceptItem(event, requiresCommit: true)
                guard let text = event["transcript"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw Failure(message: "Realtime transcription returned no text.")
                }
                transcript = text
                if preview != text { preview = text; onDelta(text) }
                completeIfReady()
            case "conversation.item.input_audio_transcription.failed", "error":
                // Server messages may echo credentials or sensitive input values.
                throw Failure(message: "OpenAI realtime transcription failed. Check the API key, model access, and available quota.")
            case "session.closed":
                throw Failure(message: "The realtime connection closed before transcription completed.")
            default:
                break
            }
        } catch {
            fail(error)
        }
        return state == .connecting || state == .ready
    }

    private func acceptItem(_ event: [String: Any], requiresCommit: Bool = false) throws {
        guard state == .ready, !requiresCommit || (finishing && commitStarted),
              let receivedID = event["item_id"] as? String,
              !receivedID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(message: "Realtime transcription returned an unexpected turn.")
        }
        if let itemID, itemID != receivedID {
            throw Failure(message: "Realtime transcription returned more than one audio turn.")
        }
        itemID = receivedID
    }

    private func completeIfReady() {
        guard state == .ready, finishing, commitSent, commitAcknowledged, let transcript else { return }
        state = .finished
        let waiter = finishWaiter
        finishWaiter = nil
        closeConnection()
        waiter?.resume(returning: transcript)
    }

    private func fail(_ error: Error) {
        guard state != .finished, state != .failed else { return }
        terminalError = error
        state = .failed
        let starting = startWaiter
        let ending = finishWaiter
        startWaiter = nil
        finishWaiter = nil
        closeConnection()
        starting?.resume(throwing: error)
        ending?.resume(throwing: error)
    }

    private func closeConnection() {
        startTimer?.cancel()
        finishTimer?.cancel()
        configurationTask?.cancel()
        sendTask?.cancel()
        receiveTask?.cancel()
        startTimer = nil
        finishTimer = nil
        configurationTask = nil
        sendTask = nil
        receiveTask = nil
        socket?.cancel(with: state == .finished ? .normalClosure : .goingAway, reason: nil)
        session?.invalidateAndCancel()
        socket = nil
        session = nil
        pendingPCM.removeAll()
        pendingBytes = 0
        pendingIndex = 0
    }

    deinit {
        startTimer?.cancel()
        finishTimer?.cancel()
        configurationTask?.cancel()
        sendTask?.cancel()
        receiveTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }
}
