import Foundation
import Testing
@testable import WhisperCore

@Suite(.timeLimit(.minutes(1)))
struct RealtimeTranscriberTests {
    // Public start is only called for local rejection or after a synthetic handshake.
    // prepareStart and receive exercise the real actor without opening a WebSocket.
    private func makeTranscriber(
        apiKey: String = "", model: String = "gpt-live-transcribe", language: String = "auto",
        terms: [String] = [],
        onDelta: @escaping @Sendable (String) -> Void = { _ in Issue.record("Unexpected transcript delta") }
    ) -> RealtimeTranscriber {
        RealtimeTranscriber(apiKey: apiKey, model: model, language: language,
                            vocabulary: terms.map { .init(term: $0) }, onDelta: onDelta)
    }

    private func assertFailure<T>(_ message: String, operation: () async throws -> T) async {
        do {
            _ = try await operation()
            Issue.record("Expected failure: \(message)")
        } catch {
            #expect(error.localizedDescription == message)
        }
    }

    private func pcm(_ sample: Int16, count: Int) -> Data {
        let bytes = [UInt8(truncatingIfNeeded: sample), UInt8(truncatingIfNeeded: sample >> 8)]
        return Data(Array(repeating: bytes, count: count).joined())
    }

    private func makeReady(
        onDelta: @escaping @Sendable (String) -> Void = { _ in Issue.record("Unexpected transcript delta") }
    ) async throws -> RealtimeTranscriber {
        let transcriber = makeTranscriber(apiKey: "unused-test-key", onDelta: onDelta)
        _ = try await transcriber.prepareStart()
        await transcriber.didSendConfiguration()
        #expect(await transcriber.receive(.string(#"{"type":"session.updated"}"#)))
        return transcriber
    }

    private func configuration(model: String = "gpt-live-transcribe", language: String = "auto",
                               terms: [String] = []) async throws -> [String: Any] {
        let transcriber = makeTranscriber(apiKey: "unused-test-key", model: model, language: language, terms: terms)
        let update = try await transcriber.prepareStart()
        await transcriber.cancel()
        let text = try #require(update)
        let event = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(event["type"] as? String == "session.update")
        let session = try #require(event["session"] as? [String: Any])
        #expect(session["type"] as? String == "transcription")
        let audio = try #require(session["audio"] as? [String: Any])
        let input = try #require(audio["input"] as? [String: Any])
        #expect(input["turn_detection"] is NSNull)
        let format = try #require(input["format"] as? [String: Any])
        #expect(format["type"] as? String == "audio/pcm")
        #expect(format["rate"] as? Int == 24_000)
        #expect((input["noise_reduction"] as? [String: String])?["type"] == "near_field")
        return try #require(input["transcription"] as? [String: Any])
    }

    @Test func cancellationIsIdempotentAndTerminal() async throws {
        let transcriber = makeTranscriber()
        try await transcriber.append(pcm(100, count: 240))
        await transcriber.cancel()
        await transcriber.cancel()
        await #expect(throws: CancellationError.self) { try await transcriber.start() }
        await #expect(throws: CancellationError.self) { try await transcriber.append(Data()) }
        await #expect(throws: CancellationError.self) { try await transcriber.append(pcm(100, count: 240)) }
        await #expect(throws: CancellationError.self) { try await transcriber.finish() }
        #expect(await transcriber.receive(.string(#"{"type":"session.updated"}"#)) == false)
    }

    @Test func alreadyCancelledStartDoesNotOpenAConnection() async {
        let transcriber = makeTranscriber()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await transcriber.start()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        await #expect(throws: CancellationError.self) { try await transcriber.append(Data()) }
        await #expect(throws: CancellationError.self) { try await transcriber.finish() }
        await transcriber.cancel()
    }

    @Test func cancelledAppendIsTerminal() async {
        let transcriber = makeTranscriber()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await transcriber.append(pcm(100, count: 240))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        await #expect(throws: CancellationError.self) { try await transcriber.start() }
        await #expect(throws: CancellationError.self) { try await transcriber.finish() }
    }

    @Test(arguments: ["", "   ", "\r\n\t"], [false, true])
    func emptyKeyOrModelFailsBeforeNetworking(empty: String, invalidModel: Bool) async throws {
        let transcriber = makeTranscriber(apiKey: invalidModel ? "unused-test-key" : empty,
                                          model: invalidModel ? empty : "gpt-live-transcribe")
        try await transcriber.append(pcm(100, count: 240))
        let message = "A realtime API key and transcription model are required."
        await assertFailure(message) { try await transcriber.start() }
        await transcriber.cancel()
        await assertFailure(message) { try await transcriber.start() }
        await assertFailure(message) { try await transcriber.append(Data()) }
        await assertFailure(message) { try await transcriber.finish() }
    }

    @Test(arguments: [1, 3])
    func oddLengthPCMIsTerminal(byteCount: Int) async {
        let transcriber = makeTranscriber()
        let message = "Realtime audio must contain complete PCM16 samples."
        await assertFailure(message) { try await transcriber.append(Data(repeating: 0, count: byteCount)) }
        await transcriber.cancel()
        await assertFailure(message) { try await transcriber.append(Data([0, 0])) }
        await assertFailure(message) { try await transcriber.start() }
        await assertFailure(message) { try await transcriber.finish() }
    }

    @Test(arguments: [1, 2, 16])
    func pendingBufferAcceptsExactLimitThenFailsTerminally(chunks: Int) async throws {
        let transcriber = makeTranscriber()
        for _ in 0..<chunks {
            try await transcriber.append(Data(repeating: 0, count: 1_048_576 / chunks))
        }
        try await transcriber.append(Data())
        let message = "Realtime audio buffering exceeded its limit. Use file transcription instead."
        await assertFailure(message) { try await transcriber.append(Data([0, 0])) }
        await assertFailure(message) { try await transcriber.append(Data()) }
        await assertFailure(message) { try await transcriber.start() }
        await assertFailure(message) { try await transcriber.finish() }
    }

    @Test func oversizedSingleChunkIsRejected() async {
        let transcriber = makeTranscriber()
        await assertFailure("Realtime audio buffering exceeded its limit. Use file transcription instead.") {
            try await transcriber.append(Data(repeating: 0, count: 1_048_578))
        }
    }

    @Test(arguments: [0, 2_400])
    func finishBeforeStartDoesNotConsumeRecording(samples: Int) async throws {
        let transcriber = makeTranscriber()
        try await transcriber.append(pcm(100, count: samples))
        await assertFailure("Start realtime transcription before finishing it.") { try await transcriber.finish() }
        try await transcriber.append(pcm(100, count: 240))
        await transcriber.cancel()
    }

    @Test(arguments: [false, true])
    func silentOrShortPCMIsTerminal(ready: Bool) async throws {
        let recordings = [Data(), pcm(0, count: 2_400), pcm(3, count: 2_400), pcm(-3, count: 2_400),
                          pcm(4, count: 2_399), pcm(-4, count: 2_399), pcm(.min, count: 2_399),
                          pcm(100, count: 239) + pcm(0, count: 2_161)]
        for recording in recordings {
            let transcriber = makeTranscriber(apiKey: "unused-test-key")
            try await transcriber.append(recording)
            _ = try await transcriber.prepareStart()
            if ready {
                await transcriber.didSendConfiguration()
                #expect(await transcriber.receive(.string(#"{"type":"session.updated"}"#)))
            }
            let message = "The recording is silent or shorter than 100 milliseconds."
            await assertFailure(message) { try await transcriber.finish() }
            await assertFailure(message) { try await transcriber.append(Data()) }
            await assertFailure(message) { try await transcriber.start() }
            await assertFailure(message) { try await transcriber.finish() }
        }
    }

    @Test(arguments: [false, true])
    func readinessRequiresConfigurationSendAndAcknowledgement(acknowledgementFirst: Bool) async throws {
        let transcriber = makeTranscriber(apiKey: "unused-test-key")
        _ = try await transcriber.prepareStart()
        if acknowledgementFirst {
            #expect(await transcriber.receive(.string(#"{"type":"session.updated"}"#)))
        } else {
            await transcriber.didSendConfiguration()
        }
        await assertFailure("The realtime session has already been started.") { try await transcriber.start() }
        if acknowledgementFirst {
            await transcriber.didSendConfiguration()
        } else {
            #expect(await transcriber.receive(.string(#"{"type":"session.updated"}"#)))
        }
        try await transcriber.start()
        try await transcriber.start()
        await transcriber.cancel()
    }

    @Test func liveDeltasArriveBeforeCommitAndStayOnOneItem() async throws {
        let deltas = AsyncStream<String>.makeStream()
        defer { deltas.continuation.finish() }
        let transcriber = try await makeReady { deltas.continuation.yield($0) }
        #expect(await transcriber.receive(.string(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"item_1","delta":"Hello, "}"#)))
        #expect(await transcriber.receive(.data(Data(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"item_1","delta":"world."}"#.utf8))))
        #expect(await transcriber.receive(.string(#"{"type":"rate_limits.updated"}"#)))
        #expect(await transcriber.receive(.string(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"item_2","delta":"Wrong turn"}"#)) == false)
        await assertFailure("Realtime transcription returned more than one audio turn.") { try await transcriber.finish() }
        #expect(await transcriber.receive(.string(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"item_1","delta":"Late"}"#)) == false)
        deltas.continuation.finish()
        var received: [String] = []
        for await text in deltas.stream { received.append(text) }
        #expect(received == ["Hello, ", "Hello, world."])
    }

    @Test(arguments: ["not json", "[]", "{}", #"{"type":1}"#])
    func malformedEventsFailWithoutWaitingForTimeout(json: String) async throws {
        let transcriber = try await makeReady()
        #expect(await transcriber.receive(.string(json)) == false)
        await #expect(throws: (any Error).self) { try await transcriber.finish() }
        await #expect(throws: (any Error).self) { try await transcriber.append(Data()) }
    }

    @Test(arguments: ["", #", "item_id":null"#, #", "item_id":123"#, #", "item_id":"""#, #", "item_id":" \r\n ""#])
    func missingOrInvalidItemIDIsTerminal(itemField: String) async throws {
        let transcriber = try await makeReady()
        let json = #"{"type":"conversation.item.input_audio_transcription.delta","delta":"Hello""# + itemField + "}"
        #expect(await transcriber.receive(.string(json)) == false)
        let message = "Realtime transcription returned an unexpected turn."
        await assertFailure(message) { try await transcriber.finish() }
        await assertFailure(message) { try await transcriber.start() }
    }

    @Test(arguments: ["input_audio_buffer.committed", "conversation.item.input_audio_transcription.completed"])
    func commitEventsBeforeManualCommitAreTerminal(type: String) async throws {
        let transcriber = try await makeReady()
        let event = ["type": type, "item_id": "item_1", "transcript": "Unexpected"]
        #expect(await transcriber.receive(.data(try JSONSerialization.data(withJSONObject: event))) == false)
        await assertFailure("Realtime transcription returned an unexpected turn.") { try await transcriber.finish() }
    }

    @Test(arguments: ["error", "conversation.item.input_audio_transcription.failed", "session.closed"])
    func serverFailureIsTerminal(type: String) async throws {
        let transcriber = try await makeReady()
        let event: [String: Any] = ["type": type, "error": ["message": "Synthetic failure echoing sk-secret-do-not-expose"]]
        #expect(await transcriber.receive(.data(try JSONSerialization.data(withJSONObject: event))) == false)
        await transcriber.cancel()
        let message = type == "session.closed"
            ? "The realtime connection closed before transcription completed."
            : "OpenAI realtime transcription failed. Check the API key, model access, and available quota."
        await assertFailure(message) { try await transcriber.finish() }
        await assertFailure(message) { try await transcriber.append(Data()) }
    }

    @Test(arguments: ["gpt-live-transcribe", "gpt-live-transcribe-2026-08-01", "gpt-transcribe", "gpt-transcribe-2026-08-01"])
    func newModelConfigurationFiltersInvalidKeywordsAndUsesPluralLanguages(model: String) async throws {
        let transcription = try await configuration(model: " \(model)\n", language: " en ", terms: [
            " Acme ", "Acme", "", " \n ", "List<T>", "a<b", "a>b", "a\rb", "a\nb", "a\r\nb",
            String(repeating: "x", count: 121), "C++", "quoted\"term", "back\\slash", "Valid after invalid"
        ])
        #expect(transcription["model"] as? String == model)
        #expect(transcription["languages"] as? [String] == ["en"])
        #expect(transcription["language"] == nil)
        #expect(transcription["keywords"] as? [String] == ["Acme", "C++", "quoted\"term", "back\\slash", "Valid after invalid"])
        #expect(transcription["prompt"] == nil)
        #expect(transcription["delay"] as? String == (model.hasPrefix("gpt-live-transcribe") ? "medium" : nil))
    }

    @Test func keywordBoundsApplyAfterFilteringAndDeduplication() async throws {
        let longest = String(repeating: "x", count: 120)
        let terms = [String(repeating: "y", count: 121), "List<T>", longest, longest] + (0..<150).map { "term-\($0)" }
        let transcription = try await configuration(terms: terms)
        let keywords = try #require(transcription["keywords"] as? [String])
        #expect(keywords == [longest] + (0..<99).map { "term-\($0)" })
        #expect(keywords.allSatisfy { $0.count <= 120 })
    }

    @Test(arguments: ["", " \n ", "auto", " AuTo "], ["gpt-live-transcribe", "gpt-transcribe", "gpt-4o-transcribe"])
    func automaticLanguageAndEmptyHintsAreOmitted(language: String, model: String) async throws {
        let transcription = try await configuration(model: model, language: language, terms: ["", " \n "])
        #expect(transcription["language"] == nil)
        #expect(transcription["languages"] == nil)
        #expect(transcription["keywords"] == nil)
        #expect(transcription["prompt"] == nil)
    }

    @Test func allInvalidKeywordsAreOmittedWithoutRejectingSession() async throws {
        let transcription = try await configuration(terms: ["List<T>", "a\nb", String(repeating: "x", count: 121)])
        #expect(transcription["keywords"] == nil)
        #expect(transcription["prompt"] == nil)
        #expect(transcription["delay"] as? String == "medium")
    }

    @Test(arguments: ["whisper-1", "gpt-4o-transcribe", "gpt-4o-mini-transcribe"])
    func legacyModelsUseBoundedPromptAndSingularLanguage(model: String) async throws {
        let terms = ["List<T>"] + (0..<100).map { "term-\($0)-" + String(repeating: "x", count: 100) }
        let transcription = try await configuration(model: model, language: "fr", terms: terms)
        #expect(transcription["language"] as? String == "fr")
        #expect(transcription["languages"] == nil)
        #expect(transcription["keywords"] == nil)
        #expect(transcription["delay"] == nil)
        let prompt = try #require(transcription["prompt"] as? String)
        #expect(prompt.count == 1_200)
        #expect(prompt == String(terms.joined(separator: ", ").prefix(1_200)))
    }
}
