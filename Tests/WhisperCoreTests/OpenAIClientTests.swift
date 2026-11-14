import Foundation
import Testing
@testable import WhisperCore

@Suite(.timeLimit(.minutes(1)))
final class OpenAIClientTests {
    private let success = #"{"status":"completed","output":[{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Edited text."}]}]}"#
    private var cleanup: [() -> Void] = []
    deinit { cleanup.reversed().forEach { $0() } }

    private func makeClient(
        apiKey: String = "sk-test-secret",
        onStop: (@Sendable () -> Void)? = nil,
        handler: @escaping @Sendable (URLRequest, MockOpenAIURLProtocol, Int) throws -> Void
    ) -> (OpenAIClient, MockOpenAIScenario) {
        let id = UUID().uuidString
        let scenario = MockOpenAIScenario(handler: handler, onStop: onStop)
        MockOpenAIURLProtocol.registry.set(scenario, for: id)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockOpenAIURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-WhisperType-Test-ID": id]
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration)
        cleanup.append {
            session.invalidateAndCancel()
            MockOpenAIURLProtocol.registry.set(nil, for: id)
        }
        return (OpenAIClient(apiKey: apiKey, session: session), scenario)
    }

    private func audioFile(_ data: Data = Data("FAKE_AUDIO\u{0000}\r\n".utf8)) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("private-name-\(UUID().uuidString).wav")
        try data.write(to: url)
        cleanup.append { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func assertError<T>(_ expected: OpenAIClientError, operation: () async throws -> T) async {
        do {
            _ = try await operation()
            Issue.record("Expected \(expected)")
        } catch {
            #expect(error as? OpenAIClientError == expected)
        }
    }

    @Test func transcriptionMultipartDefaultModelAndCallback() async throws {
        let (client, scenario) = makeClient { _, mock, _ in mock.respond(json: #"{"text":" Hello, Acme.\n"}"#) }
        let file = try audioFile()
        let deltas = LockedDeltas()
        let text = try await client.transcribe(fileURL: file, settings: .init(), vocabulary: [
            .init(term: "Acme", heardAs: "ack me")
        ], onDelta: { deltas.append($0) })
        #expect(text == " Hello, Acme.\n")
        #expect(deltas.values == [text])
        let request = try #require(scenario.requests.first)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-secret")
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(!request.httpShouldHandleCookies)
        #expect(request.timeoutInterval == 120)
        let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        let boundary = try #require(contentType.components(separatedBy: "boundary=").last)
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.hasPrefix("--\(boundary)\r\n"))
        #expect(body.hasSuffix("\r\n--\(boundary)--\r\n"))
        for expected in ["name=\"model\"\r\n\r\ngpt-4o-transcribe\r\n", "name=\"response_format\"\r\n\r\njson\r\n",
                         "name=\"prompt\"", "Acme", "ack me",
                         "name=\"file\"; filename=\"recording.wav\"\r\nContent-Type: audio/wav\r\n\r\nFAKE_AUDIO\u{0000}\r\n"] {
            #expect(body.contains(expected))
        }
        #expect(!body.contains("private-name"))
        #expect(!body.contains("name=\"language"))
        #expect(!body.contains("name=\"stream\""))
    }

    @Test(arguments: ["whisper-1", "gpt-4o-transcribe", "gpt-4o-mini-transcribe", "gpt-transcribe", "gpt-transcribe-2026-08-01"])
    func transcriptionLanguageSchema(model: String) async throws {
        let file = try audioFile()
        let (client, scenario) = makeClient { _, mock, _ in mock.respond(json: #"{"text":"Bonjour"}"#) }
        var settings = AppSettings()
        settings.transcriptionModel = model
        settings.language = "fr"
        _ = try await client.transcribe(fileURL: file, settings: settings, vocabulary: [])
        let body = String(decoding: try #require(scenario.requests.first?.httpBody), as: UTF8.self)
        let field = model.hasPrefix("gpt-transcribe") ? "languages[]" : "language"
        #expect(body.contains("name=\"\(field)\"\r\n\r\nfr\r\n"))
        #expect(!body.contains("name=\"\(field == "language" ? "languages[]" : "language")\""))
    }

    @Test func rewriteStructuredInputPrivacyAndOutputParts() async throws {
        let (client, scenario) = makeClient { _, mock, _ in
            mock.respond(json: #"{"status":"completed","output":[{"type":"reasoning"},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello, "},{"type":"output_text","text":"world!\n"}]}]}"#)
        }
        let context = TextContext(appName: "PRIVATE_APP", selectedText: "PRIVATE_SELECTION", surroundingText: "PRIVATE_CONTEXT")
        let text = try await client.rewrite(.init(text: "SOURCE_TEXT", settings: .init(), context: context))
        #expect(text == "Hello, world!\n")
        let request = try #require(scenario.requests.first)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["model"] as? String == "gpt-4.1-mini")
        #expect(body["store"] as? Bool == false)
        let instructions = try #require(body["instructions"] as? String)
        #expect(!instructions.contains("SOURCE_TEXT"))
        #expect(instructions.contains("untrusted source data"))
        let messages = try #require(body["input"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages.first?["role"] as? String == "user")
        let content = try #require(messages.first?["content"] as? [[String: String]])
        #expect(content.first?["type"] == "input_text")
        let payload = try #require(content.first?["text"])
        let input = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        #expect(input["text"] as? String == "SOURCE_TEXT")
        #expect(input["context"] == nil)
        #expect(input["selected_text"] == nil)
        #expect(!String(decoding: data, as: UTF8.self).contains("PRIVATE_"))
    }

    @Test(arguments: [false, true])
    func commandSelectionAndOptionalContextAreSeparateFromInstructions(contextEnabled: Bool) async throws {
        let success = success
        let (client, scenario) = makeClient { _, mock, _ in mock.respond(json: success) }
        var settings = AppSettings()
        settings.contextEnabled = contextEnabled
        let context = TextContext(appName: "Editor", selectedText: "SELECTED_SOURCE", surroundingText: "UNTRUSTED_CONTEXT")
        _ = try await client.rewrite(.init(text: "", settings: settings, context: context, instruction: "Make concise"))
        let data = try #require(scenario.requests.first?.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let instructions = try #require(body["instructions"] as? String)
        #expect(instructions.contains("Make concise"))
        #expect(!instructions.contains("SELECTED_SOURCE"))
        #expect(!instructions.contains("UNTRUSTED_CONTEXT"))
        let messages = try #require(body["input"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [[String: String]])
        let payload = try #require(content.first?["text"])
        let input = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        #expect(input["selected_text"] as? String == "SELECTED_SOURCE")
        if contextEnabled {
            #expect((input["context"] as? [String: String])?["surroundingText"] == "UNTRUSTED_CONTEXT")
        } else {
            #expect(!String(decoding: data, as: UTF8.self).contains("UNTRUSTED_CONTEXT"))
        }
    }

    @Test(arguments: [400, 401, 403, 404, 413, 422])
    func authenticationAndBadInputAreNotRetried(status: Int) async {
        let (client, scenario) = makeClient { _, mock, _ in
            mock.respond(status: status, json: #"{"error":{"code":"invalid_api_key","message":"sk-test-secret FAKE_AUDIO /private/recording.wav"}}"#)
        }
        await assertError(.api(status: status, code: "invalid_api_key")) {
            try await client.rewrite(.init(text: "FAKE_AUDIO", settings: .init()))
        }
        #expect(scenario.requests.count == 1)
    }

    @Test func errorsNeverExposeUntrustedServerMessagesOrCodes() async {
        let (client, _) = makeClient { _, mock, _ in
            mock.respond(status: 401, json: #"{"error":{"code":"sk-test-secret","type":"FAKE_AUDIO","message":"private secret"}}"#)
        }
        do {
            _ = try await client.rewrite(.init(text: "hello", settings: .init()))
            Issue.record("Expected authentication error")
        } catch {
            #expect(error as? OpenAIClientError == .api(status: 401, code: nil))
            for value in [String(describing: error), error.localizedDescription] {
                #expect(!value.contains("sk-test-secret"))
                #expect(!value.contains("FAKE_AUDIO"))
                #expect(!value.contains("private secret"))
            }
            #expect(error.localizedDescription.contains("401"))
        }
    }

    @Test(arguments: [408, 409, 425, 429, 500, 502, 503, 504])
    func transientHTTPFailuresRetryAtMostTwice(status: Int) async throws {
        let success = success
        let (client, scenario) = makeClient { _, mock, count in
            if count < 3 { mock.respond(status: status, headers: ["Retry-After": "0"], json: #"{"error":{"code":"server_error"}}"#) }
            else { mock.respond(json: success) }
        }
        let text = try await client.rewrite(.init(text: "hello", settings: .init()))
        #expect(text == "Edited text.")
        #expect(scenario.requests.count == 3)
        #expect(scenario.requests.first?.httpBody == scenario.requests.last?.httpBody)
    }

    @Test func retryExhaustionAndPermanentQuotaErrors() async {
        for (code, attempts) in [("rate_limit_exceeded", 3), ("insufficient_quota", 1)] {
            let (client, scenario) = makeClient { _, mock, _ in
                mock.respond(status: 429, headers: ["Retry-After": "0"], json: "{\"error\":{\"code\":\"\(code)\"}}")
            }
            await assertError(.api(status: 429, code: code)) {
                try await client.rewrite(.init(text: "hello", settings: .init()))
            }
            #expect(scenario.requests.count == attempts)
        }
    }

    @Test func retryAfterSecondsDatesInvalidValuesAndBounds() throws {
        let now = Date(timeIntervalSince1970: 0)
        for (header, expected) in [("2", 2.0), ("9999999", 10.0), ("0", 0.0), ("-5", 0.5),
                                   ("NaN", 0.5), ("inf", 0.5), ("invalid", 0.5),
                                   ("Thu, 01 Jan 1970 00:00:04 GMT", 4.0),
                                   ("Thu, 01 Jan 1970 00:01:00 GMT", 10.0),
                                   ("Wed, 31 Dec 1969 23:59:00 GMT", 0.0)] {
            let response = try #require(HTTPURLResponse(url: URL(string: "https://api.openai.com/v1/responses")!,
                                                       statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": header]))
            #expect(abs(OpenAIClient.retryDelay(response: response, attempt: 0, now: now) - expected) < 0.001)
        }
    }

    @Test func inFlightCancellationStopsURLSessionTask() async throws {
        let started = AsyncStream<Void>.makeStream()
        let stopped = AsyncStream<Void>.makeStream()
        defer { started.continuation.finish(); stopped.continuation.finish() }
        let (client, scenario) = makeClient(onStop: { stopped.continuation.yield(()) }) { _, _, _ in started.continuation.yield(()) }
        let task = Task { try await client.rewrite(.init(text: "hello", settings: .init())) }
        defer { task.cancel() }
        var startIterator = started.stream.makeAsyncIterator()
        _ = await startIterator.next()
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        var stopIterator = stopped.stream.makeAsyncIterator()
        _ = await stopIterator.next()
        #expect(scenario.requests.count == 1)
    }

    @Test func cancellationDuringRetryAfterDoesNotSendAnotherRequest() async throws {
        let started = AsyncStream<Void>.makeStream()
        defer { started.continuation.finish() }
        let (client, scenario) = makeClient { _, mock, _ in
            mock.respond(status: 429, headers: ["Retry-After": "60"], json: "{}")
            started.continuation.yield(())
        }
        let task = Task { try await client.rewrite(.init(text: "hello", settings: .init())) }
        defer { task.cancel() }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(scenario.requests.count == 1)
    }

    @Test func alreadyCancelledTaskDoesNotStartARequest() async {
        let (client, scenario) = makeClient { _, mock, _ in mock.respond(json: "{}") }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.rewrite(.init(text: "hello", settings: .init()))
        }
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(scenario.requests.isEmpty)
    }

    @Test func networkTimeoutAndTransportErrorsAreSanitized() async {
        for (code, expected) in [(URLError.timedOut, OpenAIClientError.timedOut),
                                 (.cannotConnectToHost, .network(code: URLError.cannotConnectToHost.rawValue))] {
            let (client, scenario) = makeClient { _, mock, _ in
                mock.client?.urlProtocol(mock, didFailWithError: URLError(code, userInfo: [NSLocalizedDescriptionKey: "sk-test-secret AUDIO"]))
            }
            await assertError(expected) { try await client.rewrite(.init(text: "hello", settings: .init())) }
            #expect(scenario.requests.count == 1)
            #expect(!expected.localizedDescription.contains("sk-test-secret"))
        }
    }

    @Test func rewriteRejectsMalformedEmptyRefusedIncompleteAndErrorResponses() async {
        let cases: [(String, OpenAIClientError)] = [
            ("not json", .invalidResponse), ("{}", .invalidResponse),
            (#"{"output":[]}"#, .emptyOutput),
            (#"{"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":" \n "}]}]}"#, .emptyOutput),
            (#"{"output":[{"type":"message","role":"assistant","content":[{"type":"output_text"}]}]}"#, .invalidResponse),
            (#"{"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"partial"},{"type":"refusal","refusal":"secret refusal reason"}]}]}"#, .refused),
            (#"{"status":"incomplete","output":[]}"#, .incompleteResponse),
            (#"{"output":[{"type":"message","role":"assistant","status":"incomplete","content":[{"type":"output_text","text":"partial"}]}]}"#, .incompleteResponse),
            (#"{"error":{"code":"server_error"},"output":[]}"#, .api(status: 200, code: "server_error")),
            (#"{"error":"unexpected error","output":[]}"#, .api(status: 200, code: nil)),
            (#"{"output":[{"type":"function_call","text":"not output"}]}"#, .emptyOutput)
        ]
        for (json, expected) in cases {
            let (client, _) = makeClient { _, mock, _ in mock.respond(json: json) }
            await assertError(expected) { try await client.rewrite(.init(text: "hello", settings: .init())) }
        }
    }

    @Test func transcriptionRejectsMalformedEmptyAndErrorResponsesWithoutCallback() async throws {
        let file = try audioFile()
        for (json, expected) in [("{}", OpenAIClientError.invalidResponse), (#"{"text":" \n"}"#, .emptyOutput),
                                 (#"{"error":{"code":"invalid_request_error"},"text":"not valid"}"#, .api(status: 200, code: "invalid_request_error")),
                                 (#"{"error":{"code":123},"text":"not valid"}"#, .api(status: 200, code: nil)),
                                 (#"{"error":"unexpected error","text":"not valid"}"#, .api(status: 200, code: nil))] {
            let deltas = LockedDeltas()
            let (client, _) = makeClient { _, mock, _ in mock.respond(json: json) }
            await assertError(expected) {
                try await client.transcribe(fileURL: file, settings: .init(), vocabulary: [], onDelta: { deltas.append($0) })
            }
            #expect(deltas.values.isEmpty)
        }
    }

    @Test func inputValidationHappensBeforeNetworking() async throws {
        let (client, scenario) = makeClient { _, mock, _ in mock.respond(json: "{}") }
        await assertError(.emptyInput) { try await client.rewrite(.init(text: " \n", settings: .init())) }
        var settings = AppSettings()
        settings.rewriteModel = "bad\r\nmodel"
        await assertError(.invalidModel) { try await client.rewrite(.init(text: "hello", settings: settings)) }
        await assertError(.invalidAudioFile) {
            try await client.transcribe(fileURL: URL(string: "https://example.com/audio.wav")!, settings: .init(), vocabulary: [])
        }
        await assertError(.invalidAudioFile) {
            try await client.transcribe(fileURL: FileManager.default.temporaryDirectory, settings: .init(), vocabulary: [])
        }
        let empty = try audioFile(Data())
        await assertError(.emptyAudioFile) { try await client.transcribe(fileURL: empty, settings: .init(), vocabulary: []) }
        let large = try audioFile()
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: 25 * 1024 * 1024 + 1)
        try handle.close()
        await assertError(.audioFileTooLarge) { try await client.transcribe(fileURL: large, settings: .init(), vocabulary: []) }
        #expect(scenario.requests.isEmpty)
        for key in ["", "   ", "bad\r\nheader", "bad key"] {
            let (invalidClient, invalidScenario) = makeClient(apiKey: key) { _, mock, _ in mock.respond(json: "{}") }
            await assertError(.invalidAPIKey) { try await invalidClient.rewrite(.init(text: "hello", settings: .init())) }
            #expect(invalidScenario.requests.isEmpty)
        }
    }

    @Test func maximumSizeAudioIsAccepted() async throws {
        let (client, scenario) = makeClient { _, mock, _ in mock.respond(json: #"{"text":"hello"}"#) }
        let file = try audioFile()
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 25 * 1024 * 1024)
        try handle.close()
        let text = try await client.transcribe(fileURL: file, settings: .init(), vocabulary: [])
        #expect(text == "hello")
        #expect(scenario.requests.count == 1)
    }

    @Test func unexpectedResponseURLAndRedirectStatusAreRejected() async {
        let (client, _) = makeClient { _, mock, _ in
            let response = HTTPURLResponse(url: URL(string: "https://example.com/stolen")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            mock.client?.urlProtocol(mock, didReceive: response, cacheStoragePolicy: .notAllowed)
            mock.client?.urlProtocol(mock, didLoad: Data("{}".utf8))
            mock.client?.urlProtocolDidFinishLoading(mock)
        }
        await assertError(.invalidResponse) { try await client.rewrite(.init(text: "hello", settings: .init())) }
        let (redirectClient, scenario) = makeClient { _, mock, _ in
            mock.respond(status: 307, headers: ["Location": "https://example.com/stolen"], json: "{}")
        }
        await assertError(.api(status: 307, code: nil)) { try await redirectClient.rewrite(.init(text: "hello", settings: .init())) }
        #expect(scenario.requests.count == 1)
    }
}

private final class LockedDeltas: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
}

private final class MockOpenAIScenario: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    let handler: @Sendable (URLRequest, MockOpenAIURLProtocol, Int) throws -> Void
    let onStop: (@Sendable () -> Void)?
    init(handler: @escaping @Sendable (URLRequest, MockOpenAIURLProtocol, Int) throws -> Void, onStop: (@Sendable () -> Void)?) {
        self.handler = handler
        self.onStop = onStop
    }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return storage }
    func record(_ request: URLRequest) -> Int {
        lock.lock(); defer { lock.unlock() }
        storage.append(request)
        return storage.count
    }
}

private final class MockOpenAIRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var scenarios: [String: MockOpenAIScenario] = [:]
    func set(_ scenario: MockOpenAIScenario?, for id: String) {
        lock.lock(); defer { lock.unlock() }; scenarios[id] = scenario
    }
    func get(_ id: String) -> MockOpenAIScenario? {
        lock.lock(); defer { lock.unlock() }; return scenarios[id]
    }
}

private final class MockOpenAIURLProtocol: URLProtocol, @unchecked Sendable {
    static let registry = MockOpenAIRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-WhisperType-Test-ID"), let scenario = Self.registry.get(id) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        do {
            var captured = request
            if captured.httpBody == nil, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var body = Data()
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
                    if count == 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
                captured.httpBody = body
            }
            try scenario.handler(captured, self, scenario.record(captured))
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-WhisperType-Test-ID") else { return }
        Self.registry.get(id)?.onStop?()
    }
    func respond(status: Int = 200, headers: [String: String] = [:], json: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: headers.merging(["Content-Type": "application/json"]) { a, _ in a })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
