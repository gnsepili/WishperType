import Foundation

public enum OpenAIClientError: Error, LocalizedError, Equatable, Sendable {
    case invalidAPIKey
    case invalidModel
    case invalidAudioFile
    case emptyAudioFile
    case audioFileTooLarge
    case emptyInput
    case invalidResponse
    case emptyOutput
    case refused
    case incompleteResponse
    case timedOut
    case network(code: Int)
    case api(status: Int, code: String?)

    public var errorDescription: String? {
        switch self {
        case .invalidAPIKey: return "Enter a valid OpenAI API key in Settings."
        case .invalidModel: return "Choose a valid OpenAI model in Settings."
        case .invalidAudioFile: return "The recording could not be read. Choose a local audio file and try again."
        case .emptyAudioFile: return "The recording is empty. Record some audio and try again."
        case .audioFileTooLarge: return "The recording exceeds the 25 MB upload limit. Use a shorter recording."
        case .emptyInput: return "There is no text to rewrite."
        case .invalidResponse: return "OpenAI returned an invalid response. Try again."
        case .emptyOutput: return "OpenAI returned no text. Try again."
        case .refused: return "OpenAI declined to process this text."
        case .incompleteResponse: return "OpenAI returned an incomplete result. Try a shorter input."
        case .timedOut: return "The OpenAI request timed out. Check your connection and try again."
        case .network(let code): return "Could not reach OpenAI (network code \(code)). Check your connection and try again."
        case .api(let status, let code):
            let detail = code.map { ", code \($0)" } ?? ""
            let advice: String
            switch status {
            case 401: advice = "Check your API key in Settings."
            case 403: advice = "Check your OpenAI project and model permissions."
            case 429: advice = "Check your OpenAI quota or try again later."
            case 400, 404, 413, 422: advice = "Check the selected model and input."
            default: advice = "Try again later."
            }
            return "OpenAI request failed (HTTP \(status)\(detail)). \(advice)"
        }
    }
}

public struct OpenAIClient: Sendable {
    private let apiKey: String
    private let session: URLSession
    private static let maximumAudioBytes = 25 * 1024 * 1024
    private static let transcriptionURL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    private static let responsesURL = URL(string: "https://api.openai.com/v1/responses")!

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    /// Uses JSON transcription; when supplied, onDelta receives the completed transcript once.
    public func transcribe(
        fileURL: URL,
        settings: AppSettings,
        vocabulary: [VocabularyEntry],
        onDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        try Task.checkCancellation()
        var request = try makeRequest(url: Self.transcriptionURL, model: settings.transcriptionModel)
        guard fileURL.isFileURL else { throw OpenAIClientError.invalidAudioFile }
        var audio = Data()
        do {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw OpenAIClientError.invalidAudioFile }
            guard (values.fileSize ?? 0) <= Self.maximumAudioBytes else { throw OpenAIClientError.audioFileTooLarge }
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            // Bound actual bytes as well as metadata, including files that grow while being read.
            while true {
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: min(64 * 1024, Self.maximumAudioBytes + 1 - audio.count)) ?? Data()
                if chunk.isEmpty { break }
                audio.append(chunk)
                guard audio.count <= Self.maximumAudioBytes else { throw OpenAIClientError.audioFileTooLarge }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OpenAIClientError {
            throw error
        } catch {
            throw OpenAIClientError.invalidAudioFile
        }
        guard !audio.isEmpty else { throw OpenAIClientError.emptyAudioFile }

        let boundary = "WhisperType-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        let model = settings.transcriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        field("model", model)
        field("response_format", "json")
        field("prompt", TextProcessing.transcriptionPrompt(vocabulary: vocabulary))
        let language = settings.language.trimmingCharacters(in: .whitespacesAndNewlines)
        if !language.isEmpty && language.lowercased() != "auto" {
            field(model == "gpt-transcribe" || model.hasPrefix("gpt-transcribe-") ? "languages[]" : "language", language)
        }
        let formats = ["wav": "audio/wav", "mp3": "audio/mpeg", "mpga": "audio/mpeg", "mpeg": "audio/mpeg",
                       "m4a": "audio/mp4", "mp4": "audio/mp4", "webm": "audio/webm", "ogg": "audio/ogg", "flac": "audio/flac"]
        let ext = fileURL.pathExtension.lowercased()
        let safeExtension = formats[ext] == nil ? "bin" : ext
        let mime = formats[ext] ?? "application/octet-stream"
        // Never include a user's path or filename in the request or an error.
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.\(safeExtension)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let data = try await perform(request)
        guard let response = try? JSONDecoder().decode(Transcription.self, from: data) else {
            throw OpenAIClientError.invalidResponse
        }
        guard !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw OpenAIClientError.emptyOutput }
        try Task.checkCancellation()
        onDelta?(response.text)
        return response.text
    }

    public func rewrite(_ request: RewriteRequest) async throws -> String {
        try Task.checkCancellation()
        var urlRequest = try makeRequest(url: Self.responsesURL, model: request.settings.rewriteModel)
        let isCommand = !(request.instruction?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let selection = isCommand ? request.context.selectedText : ""
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw OpenAIClientError.emptyInput }
        let input = RewriteInput(
            text: request.text,
            selected_text: selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : selection,
            context: request.settings.contextEnabled ? request.context : nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let inputText = String(decoding: try encoder.encode(input), as: UTF8.self)
        let body = ResponseRequest(
            model: request.settings.rewriteModel.trimmingCharacters(in: .whitespacesAndNewlines),
            instructions: TextProcessing.rewriteInstructions(for: request),
            input: [.init(role: "user", content: [.init(type: "input_text", text: inputText)])]
        )
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(body)
        let data = try await perform(urlRequest)
        guard let response = try? JSONDecoder().decode(ResponsesOutput.self, from: data) else {
            throw OpenAIClientError.invalidResponse
        }
        if let status = response.status, status != "completed" { throw OpenAIClientError.incompleteResponse }
        var text = ""
        for item in response.output {
            guard item.type == "message", item.role == "assistant" else { continue }
            if let status = item.status, status != "completed" { throw OpenAIClientError.incompleteResponse }
            for content in item.content ?? [] {
                if content.type == "refusal" { throw OpenAIClientError.refused }
                if content.type == "output_text" {
                    guard let part = content.text else { throw OpenAIClientError.invalidResponse }
                    text += part
                }
            }
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw OpenAIClientError.emptyOutput }
        try Task.checkCancellation()
        return text
    }

    private func makeRequest(url: URL, model: String) throws -> URLRequest {
        guard !apiKey.isEmpty, apiKey.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            throw OpenAIClientError.invalidAPIKey
        }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.count <= 200,
              model.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_.:".unicodeScalars.contains($0) }) else {
            throw OpenAIClientError.invalidModel
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        // The request timeout is an inactivity timeout. Also bound total time, including retries.
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                for attempt in 0...2 {
                    try Task.checkCancellation()
                    let data: Data
                    let response: URLResponse
                    do {
                        (data, response) = try await session.data(for: request, delegate: NoRedirectDelegate())
                    } catch {
                        if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                        if (error as? URLError)?.code == .timedOut { throw OpenAIClientError.timedOut }
                        throw OpenAIClientError.network(code: (error as? URLError)?.errorCode ?? URLError.unknown.rawValue)
                    }
                    try Task.checkCancellation()
                    guard let http = response as? HTTPURLResponse, http.url == request.url else {
                        throw OpenAIClientError.invalidResponse
                    }
                    let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
                    if (200..<300).contains(http.statusCode), envelope?.hasError != true { return data }
                    if attempt < 2, envelope?.error?.safeCode != "insufficient_quota",
                       [408, 409, 425, 429, 500, 502, 503, 504].contains(http.statusCode) {
                        let delay = Self.retryDelay(response: http, attempt: attempt)
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continue
                    }
                    throw OpenAIClientError.api(status: http.statusCode, code: envelope?.error?.safeCode)
                }
                throw OpenAIClientError.invalidResponse
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 180 * 1_000_000_000)
                throw OpenAIClientError.timedOut
            }
            defer { group.cancelAll() }
            guard let data = try await group.next() else { throw OpenAIClientError.invalidResponse }
            try Task.checkCancellation()
            return data
        }
    }

    static func retryDelay(response: HTTPURLResponse, attempt: Int, now: Date = Date()) -> TimeInterval {
        if let value = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return min(seconds, 10) }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: value) { return min(max(date.timeIntervalSince(now), 0), 10) }
        }
        return min(0.5 * pow(2, Double(attempt)), 10)
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct Transcription: Decodable { let text: String }

private struct RewriteInput: Encodable {
    let text: String
    let selected_text: String?
    let context: TextContext?
}

private struct ResponseRequest: Encodable {
    struct Message: Encodable {
        struct Content: Encodable { let type: String; let text: String }
        let role: String
        let content: [Content]
    }
    let model: String
    let store = false
    let instructions: String
    let input: [Message]
}

private struct ResponsesOutput: Decodable {
    struct Output: Decodable {
        struct Content: Decodable { let type: String; let text: String? }
        let type: String
        let role: String?
        let status: String?
        let content: [Content]?
    }
    let status: String?
    let output: [Output]
}

private struct ErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let code: String?
        let type: String?
        var safeCode: String? {
            // Server messages/codes can echo input. Only known, static identifiers may reach the UI.
            let known: Set<String> = ["invalid_api_key", "invalid_request_error", "authentication_error",
                                      "permission_denied", "model_not_found", "insufficient_quota", "rate_limit_exceeded",
                                      "context_length_exceeded", "content_policy_violation", "server_error",
                                      "audio_too_long", "unsupported_language", "invalid_value"]
            return [code, type].compactMap { $0 }.first { known.contains($0) }
        }
    }
    let error: APIError?
    let hasError: Bool

    private enum CodingKeys: String, CodingKey { case error }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasError = try container.contains(.error) && !container.decodeNil(forKey: .error)
        error = hasError ? try? container.decode(APIError.self, forKey: .error) : nil
    }
}
