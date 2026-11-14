import Foundation

public enum CleanupLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, light, polished
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum WritingStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case natural, casual, professional, concise, email, developer
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum ProcessingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case accurate, live
    public var id: String { rawValue }
    public var title: String { self == .accurate ? "Accurate (record, then transcribe)" : "Live (stream while speaking)" }
}

public enum ShortcutPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case controlOption, rightOption, fn
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .controlOption: return "Control + Option"
        case .rightOption: return "Right Option"
        case .fn: return "Fn / Globe"
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var transcriptionModel = "gpt-4o-transcribe"
    public var realtimeModel = "gpt-live-transcribe"
    public var rewriteModel = "gpt-4.1-mini"
    public var language = "auto"
    public var translationLanguage = ""
    public var cleanup: CleanupLevel = .light
    public var style: WritingStyle = .natural
    public var processingMode: ProcessingMode = .accurate
    public var shortcut: ShortcutPreset = .controlOption
    public var pipelineEnabled = true
    public var autoInsert = true
    public var contextEnabled = false
    public var restoreClipboard = true
    public var soundEffects = true
    public var retainHistory = true
    public var retainAudio = false
    public var retentionDays = 30
    public var launchAtLogin = false
    public var microphoneID = ""
    public var customInstructions = ""
    public var silenceAutoStop = false
    public var silenceSeconds: Double = 8
    public var maxRecordingSeconds: Double = 1200
    public init() {}
}

public struct VocabularyEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var term: String
    public var heardAs: String
    public init(id: UUID = UUID(), term: String, heardAs: String = "") {
        self.id = id; self.term = term; self.heardAs = heardAs
    }
}

public struct Snippet: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var trigger: String
    public var expansion: String
    public init(id: UUID = UUID(), trigger: String, expansion: String) {
        self.id = id; self.trigger = trigger; self.expansion = expansion
    }
}

public struct AppRule: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var bundleID: String
    public var appName: String
    public var style: WritingStyle
    public var instructions: String
    public init(id: UUID = UUID(), bundleID: String, appName: String, style: WritingStyle = .natural, instructions: String = "") {
        self.id = id; self.bundleID = bundleID; self.appName = appName
        self.style = style; self.instructions = instructions
    }
}

public struct CustomTransform: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var instruction: String
    public init(id: UUID = UUID(), name: String, instruction: String) {
        self.id = id; self.name = name; self.instruction = instruction
    }
    public static let defaults: [CustomTransform] = [
        .init(name: "Polish", instruction: "Improve clarity and grammar while preserving the original meaning, language, and tone."),
        .init(name: "Make concise", instruction: "Make this text concise. Preserve all important facts, names, numbers, and action items."),
        .init(name: "Professional", instruction: "Rewrite this text in a warm, professional tone. Do not invent facts."),
        .init(name: "Bullet points", instruction: "Organize this text into clear bullet points without omitting important details."),
        .init(name: "Meeting summary", instruction: "Summarize these meeting notes. Use sections Summary, Decisions, Action Items, and Open Questions. Include owners or dates only when stated. Do not invent details.")
    ]
}

public enum HistoryStatus: String, Codable, Sendable {
    case completed, failed, cancelled
}

public struct HistoryEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var duration: Double
    public var targetApp: String
    public var bundleID: String
    public var rawText: String
    public var text: String
    public var status: HistoryStatus
    public var error: String?
    public var audioFileName: String?
    public var latency: Double
    public var inserted: Bool
    public var isCommand: Bool
    public var originalText: String?
    public init(id: UUID = UUID(), createdAt: Date = Date(), duration: Double = 0,
                targetApp: String = "", bundleID: String = "", rawText: String = "", text: String = "",
                status: HistoryStatus = .completed, error: String? = nil, audioFileName: String? = nil,
                latency: Double = 0, inserted: Bool = false, isCommand: Bool = false, originalText: String? = nil) {
        self.id = id; self.createdAt = createdAt; self.duration = duration
        self.targetApp = targetApp; self.bundleID = bundleID; self.rawText = rawText; self.text = text
        self.status = status; self.error = error; self.audioFileName = audioFileName
        self.latency = latency; self.inserted = inserted; self.isCommand = isCommand; self.originalText = originalText
    }
    public var wordCount: Int { text.split(whereSeparator: { $0.isWhitespace }).count }
}

public struct TextContext: Codable, Equatable, Sendable {
    public var appName: String
    public var bundleID: String
    public var selectedText: String
    public var surroundingText: String
    public init(appName: String = "", bundleID: String = "", selectedText: String = "", surroundingText: String = "") {
        self.appName = appName; self.bundleID = bundleID
        self.selectedText = selectedText; self.surroundingText = surroundingText
    }
}

public struct RewriteRequest: Sendable {
    public var text: String
    public var settings: AppSettings
    public var context: TextContext
    public var instruction: String?
    public init(text: String, settings: AppSettings, context: TextContext = .init(), instruction: String? = nil) {
        self.text = text; self.settings = settings; self.context = context; self.instruction = instruction
    }
}

public struct LibraryData: Codable, Sendable {
    public var vocabulary: [VocabularyEntry] = []
    public var snippets: [Snippet] = []
    public var appRules: [AppRule] = []
    public var transforms = CustomTransform.defaults
    public init() {}
}
