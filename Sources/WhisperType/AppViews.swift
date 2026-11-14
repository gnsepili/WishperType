import AppKit
import SwiftUI
import WhisperCore

enum WhisperAppearance {
    static let ink = Color(red: 23 / 255, green: 37 / 255, blue: 35 / 255)
    static let canvas = Color(red: 247 / 255, green: 247 / 255, blue: 242 / 255)
    static let text = Color(red: 32 / 255, green: 44 / 255, blue: 41 / 255)
    static let secondary = Color(red: 98 / 255, green: 109 / 255, blue: 103 / 255)
    static let selection = Color(red: 41 / 255, green: 60 / 255, blue: 52 / 255)
    static let mint = Color(red: 169 / 255, green: 228 / 255, blue: 202 / 255)
    static let action = Color(red: 23 / 255, green: 107 / 255, blue: 88 / 255)
    static let line = Color(red: 222 / 255, green: 226 / 255, blue: 218 / 255)

    static func duration(_ seconds: Double) -> String {
        let value = Int(min(max(seconds.isFinite ? seconds : 0, 0), 99_999_999))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

private enum Destination: String, CaseIterable, Identifiable {
    case overview = "Overview", history = "History", dictionary = "Dictionary"
    case snippets = "Snippets", appStyles = "App Styles", transforms = "Transforms"
    case scratchpad = "Scratchpad", settings = "Settings"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .history: return "clock.arrow.circlepath"
        case .dictionary: return "character.book.closed"
        case .snippets: return "text.badge.plus"
        case .appStyles: return "app.dashed"
        case .transforms: return "wand.and.stars"
        case .scratchpad: return "square.and.pencil"
        case .settings: return "slider.horizontal.3"
        }
    }
}

@MainActor
struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var destination: Destination? = .overview
    @State private var pendingScratchpadText: String?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                ErrorNotice()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack(spacing: 8) {
                    Circle().fill(model.isRecording ? WhisperAppearance.action : WhisperAppearance.secondary)
                        .frame(width: 6, height: 6).accessibilityHidden(true)
                    Text(model.statusMessage.isEmpty ? "Ready" : model.statusMessage)
                        .lineLimit(2).help(model.statusMessage)
                    Spacer(minLength: 8)
                    if model.pendingCount > 0 {
                        Text("\(model.pendingCount) processing").monospacedDigit()
                        Button("Cancel pending", action: model.cancelPending)
                    }
                }
                .font(.system(size: 11)).foregroundStyle(WhisperAppearance.secondary)
                .padding(.horizontal, 24).padding(.vertical, 10)
            }
            .background(WhisperAppearance.canvas)
        }
        .font(.system(size: 13))
        .foregroundStyle(WhisperAppearance.text)
        .tint(WhisperAppearance.action)
        .preferredColorScheme(.light)
        .frame(minWidth: 860, idealWidth: 1100, minHeight: 600, idealHeight: 740)
        .background(MainWindowConfiguration())
        .sheet(isPresented: $model.showSetup) { SetupView().environmentObject(model) }
        .confirmationDialog("Replace the Scratchpad text?", isPresented: Binding(
            get: { pendingScratchpadText != nil },
            set: { if !$0 { pendingScratchpadText = nil } }
        ), titleVisibility: .visible) {
            Button("Replace and open Scratchpad", role: .destructive) {
                if let text = pendingScratchpadText { model.scratchpad = text }
                pendingScratchpadText = nil
                destination = .scratchpad
            }
            Button("Cancel", role: .cancel) { pendingScratchpadText = nil }
        } message: {
            Text("The history entry stays unchanged. Your current Scratchpad text will be replaced.")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "waveform").font(.system(size: 23, weight: .medium))
                    .foregroundStyle(WhisperAppearance.mint)
                Text("WhisperType").font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 24).padding(.top, 30).padding(.bottom, 32)
            Text("WORKSPACE").font(.system(size: 10, weight: .semibold)).tracking(1.5)
                .foregroundStyle(WhisperAppearance.mint.opacity(0.65)).padding(.horizontal, 25)
                .padding(.bottom, 10)
            List(selection: $destination) {
                ForEach(Destination.allCases) { item in
                    Label(item.rawValue, systemImage: item.symbol)
                        .font(.system(size: 13, weight: destination == item ? .semibold : .regular))
                        .foregroundStyle(destination == item ? WhisperAppearance.mint : Color.white.opacity(0.78))
                        .padding(.vertical, 8)
                        .listRowBackground(destination == item ? WhisperAppearance.selection : Color.clear)
                        .listRowSeparator(.hidden)
                        .tag(item)
                        .accessibilityLabel(item.rawValue)
                }
            }
            .listStyle(.sidebar).scrollContentBackground(.hidden)
            .tint(WhisperAppearance.selection)
            .environment(\.colorScheme, .dark)
            .padding(.horizontal, 10)
            VStack(alignment: .leading, spacing: 10) {
                Label(model.hasAPIKey ? "API key saved" : "API key needed",
                      systemImage: model.hasAPIKey ? "key.fill" : "key")
                    .foregroundStyle(WhisperAppearance.mint)
                Text("Cloud transcription by OpenAI")
                    .font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.6))
                if !model.hasAPIKey {
                    Button("Set up WhisperType") { model.showSetup = true }
                        .buttonStyle(.bordered).tint(WhisperAppearance.mint)
                }
            }
            .font(.system(size: 12)).padding(24)
        }
        .frame(width: 220).frame(maxHeight: .infinity)
        .background(WhisperAppearance.ink)
    }

    @ViewBuilder private var detail: some View {
        switch destination ?? .overview {
        case .overview:
            OverviewView(openSettings: { destination = .settings }, openHistory: { destination = .history })
        case .history:
            HistoryView { text in
                if !model.scratchpad.isEmpty && model.scratchpad != text {
                    pendingScratchpadText = text
                } else {
                    model.scratchpad = text
                    destination = .scratchpad
                }
            }
        case .dictionary: LibraryView(kind: .dictionary)
        case .snippets: LibraryView(kind: .snippets)
        case .appStyles: LibraryView(kind: .appStyles)
        case .transforms: LibraryView(kind: .transforms)
        case .scratchpad: ScratchpadView()
        case .settings: SettingsView(embedded: true)
        }
    }
}

private struct MainWindowConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfigurationView { ConfigurationView() }
    func updateNSView(_ nsView: ConfigurationView, context: Context) {}

    final class ConfigurationView: NSView {
        private weak var configuredWindow: NSWindow?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, configuredWindow !== window else { return }
            configuredWindow = window
            window.title = "WhisperType"
            window.contentMinSize = NSSize(width: 860, height: 600)
            if !window.isVisible { window.setContentSize(NSSize(width: 1100, height: 740)) }
        }
    }
}

private struct PageHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 28, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(WhisperAppearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Surface<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let title { Text(title).font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader) }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22).background(.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(WhisperAppearance.line, lineWidth: 1))
    }
}

private struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light))
                .foregroundStyle(WhisperAppearance.action).accessibilityHidden(true)
            Text(title).font(.system(size: 16, weight: .semibold))
            Text(message).foregroundStyle(WhisperAppearance.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 330)
        }.frame(maxWidth: .infinity).padding(.vertical, 40).padding(.horizontal, 16)
    }
}

@MainActor
private struct ErrorNotice: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let error = model.errorMessage {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
                Text(error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Button(action: model.dismissError) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).accessibilityLabel("Dismiss error").help("Dismiss error")
            }
            .font(.system(size: 12)).foregroundStyle(Color(red: 0.48, green: 0.24, blue: 0.09))
            .padding(14).background(Color(red: 1, green: 0.95, blue: 0.86))
        }
    }
}

@MainActor
private struct OverviewView: View {
    @EnvironmentObject var model: AppModel
    let openSettings: () -> Void
    let openHistory: () -> Void

    private var recordingTitle: String {
        switch model.phase {
        case .idle: return model.hasAPIKey ? "Ready when you are" : "Connect your API key"
        case .requestingPermission: return "Waiting for microphone access"
        case .recording: return "Listening"
        case .stopping: return "Finishing recording"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeading(title: "Overview", subtitle: "Dictate into your apps. Review and refine your words here.")
                Surface {
                    HStack(alignment: .top, spacing: 16) {
                        Image(systemName: model.isRecording ? "waveform" : "mic")
                            .font(.system(size: 28, weight: .light)).foregroundStyle(WhisperAppearance.action)
                            .frame(width: 60, height: 60)
                            .background(WhisperAppearance.mint.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(recordingTitle).font(.system(size: 22, weight: .semibold))
                            Text(model.isRecording ? "Speak naturally. Stop to finish, or cancel to discard." :
                                    "Focus a text field in another app, then hold \(model.settings.shortcut.title) to dictate.")
                                .foregroundStyle(WhisperAppearance.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    if model.isRecording {
                        HStack {
                            AudioLevelMeter(level: model.level, isActive: true)
                                .frame(maxWidth: 260, minHeight: 24, maxHeight: 24)
                            Spacer()
                            Text(WhisperAppearance.duration(model.elapsed)).monospacedDigit()
                                .font(.system(size: 20, weight: .medium))
                        }
                        if !model.liveTranscript.isEmpty {
                            Text(model.liveTranscript).lineLimit(5).textSelection(.enabled)
                        }
                    }
                    HStack(spacing: 12) {
                        if model.hasAPIKey {
                            Button(action: model.toggleRecording) {
                                Label(model.isRecording ? "Stop recording" : "Start recording",
                                      systemImage: model.isRecording ? "stop.fill" : "mic.fill")
                            }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(model.phase == .requestingPermission || model.phase == .stopping ||
                                      (!model.isRecording && model.isBusy && !model.settings.pipelineEnabled))
                        } else {
                            Button("Connect API key") { model.showSetup = true }
                                .buttonStyle(.borderedProminent).controlSize(.large)
                        }
                        if model.phase != .idle {
                            Button("Cancel recording", role: .cancel, action: model.cancelRecording)
                        } else {
                            Button("Import audio...", action: model.importAudio).disabled(!model.hasAPIKey)
                        }
                    }
                    Text("Starting here records for review. Use the global shortcut with another app focused to insert text there.")
                        .font(.system(size: 11)).foregroundStyle(WhisperAppearance.secondary)
                }
                if !model.microphoneGranted || !model.accessibilityGranted || !model.inputMonitoringGranted || !model.hotkeysReady {
                    Surface {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Finish setting up", systemImage: "checklist").fontWeight(.semibold)
                                Text("Microphone access enables recording. Accessibility and Input Monitoring enable global shortcuts and insertion.")
                                    .foregroundStyle(WhisperAppearance.secondary)
                            }
                            Spacer(minLength: 12)
                            Button("Review setup") { model.showSetup = true }
                        }
                    }
                }
                Surface(title: "Your shortcuts") {
                    ShortcutRows(preset: model.settings.shortcut)
                    Button("Adjust preferences", action: openSettings).buttonStyle(.link)
                }
                Surface {
                    HStack {
                        Text("Latest result").font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Button("View history", action: openHistory).buttonStyle(.link)
                    }
                    if model.lastText.isEmpty {
                        Text("Your next transcription will appear here.").foregroundStyle(WhisperAppearance.secondary)
                    } else {
                        Text(model.lastText).lineLimit(7).textSelection(.enabled).lineSpacing(4)
                        Button(action: model.copyLast) { Label("Copy text", systemImage: "doc.on.doc") }
                    }
                }
                PrivacyNote()
            }.padding(32).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
}

private struct ShortcutRows: View {
    let preset: ShortcutPreset
    private var shortcuts: [(String, String)] {
        [("Hold to dictate", preset.title), ("Toggle recording", "Control + Option + Space"),
         ("Hold for a voice command", "Control + Option + Command"),
         ("Polish selected text", "Control + Option + P"),
         ("Copy / paste last result", "Command + Control + C / V")]
    }
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 13) {
            ForEach(shortcuts, id: \.0) { item in
                GridRow {
                    Text(item.0).foregroundStyle(WhisperAppearance.secondary)
                    Text(item.1).font(.system(size: 11, weight: .medium, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }
}

private struct PrivacyNote: View {
    var body: some View {
        Label {
            Text("Transcription sends audio to OpenAI. Cleanup and transforms send text; optional context can include nearby text from the focused app. An API key, internet connection, and API usage charges apply.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "cloud").accessibilityHidden(true)
        }
        .font(.system(size: 11)).foregroundStyle(WhisperAppearance.secondary)
    }
}

@MainActor
private struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    let rewrite: (String) -> Void
    @State private var search = ""
    @State private var selection: UUID?
    @State private var showRaw = false
    @State private var deletion: HistoryEntry?
    @State private var confirmClear = false

    private var entries: [HistoryEntry] {
        model.history.filter { search.isEmpty || [$0.text, $0.rawText, $0.targetApp, $0.error ?? ""]
            .contains(where: { $0.localizedCaseInsensitiveContains(search) }) }
            .sorted { $0.createdAt > $1.createdAt }
    }
    private var selected: HistoryEntry? { entries.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeading(title: "History", subtitle: "Your saved recordings and their results.")
            HStack(spacing: 12) {
                TextField("Search transcripts or apps", text: $search)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Search history")
                Menu {
                    Button("Import audio...", action: model.importAudio).disabled(!model.hasAPIKey)
                    Button("Export history...", action: model.exportHistory).disabled(model.history.isEmpty)
                    Divider()
                    Button("Delete all history...", role: .destructive) { confirmClear = true }
                        .disabled(model.history.isEmpty)
                } label: { Label("Actions", systemImage: "ellipsis.circle") }
                .fixedSize()
            }
            if model.history.isEmpty {
                Surface {
                    EmptyState(symbol: "clock.arrow.circlepath", title: "No saved recordings",
                               message: model.settings.retainHistory ? "Record a thought or import an audio file to get started." :
                                "History is turned off. Enable it in Settings to keep future results.")
                    Button("Import audio...", action: model.importAudio).disabled(!model.hasAPIKey)
                }
                Spacer()
            } else if entries.isEmpty {
                EmptyState(symbol: "magnifyingglass", title: "No matches", message: "Try a different word or app name.")
                Spacer()
            } else {
                HStack(alignment: .top, spacing: 20) {
                    List(selection: $selection) {
                        ForEach(entries) { entry in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Text(entry.targetApp.isEmpty ? "Recording" : entry.targetApp).fontWeight(.medium).lineLimit(1)
                                    Spacer(minLength: 4)
                                    if entry.status != .completed {
                                        Image(systemName: entry.status == .failed ? "exclamationmark.circle" : "xmark.circle")
                                            .accessibilityLabel(entry.status.rawValue.capitalized)
                                    }
                                }
                                Text(entry.text.isEmpty ? (entry.rawText.isEmpty ? "No transcript" : entry.rawText) : entry.text)
                                    .lineLimit(2).foregroundStyle(WhisperAppearance.secondary)
                                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 10)).foregroundStyle(WhisperAppearance.secondary)
                            }
                            .padding(.vertical, 9).tag(entry.id)
                            .contextMenu {
                                Button("Copy text") { model.copyText(entry.text) }.disabled(entry.text.isEmpty)
                                Button("Retry audio") { model.retry(entry) }
                                    .disabled(entry.audioFileName == nil || !model.hasAPIKey)
                                Divider()
                                Button("Delete...", role: .destructive) { deletion = entry }
                            }
                        }
                    }
                    .listStyle(.inset).scrollContentBackground(.hidden)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(WhisperAppearance.line, lineWidth: 1))
                    .frame(width: 196).accessibilityLabel("Saved recordings")
                    .onDeleteCommand { if let selected { deletion = selected } }
                    ScrollView {
                        if let entry = selected { historyDetail(entry) }
                        else {
                            EmptyState(symbol: "text.alignleft", title: "Select a recording",
                                       message: "Review its text, listen to saved audio, or try a rewrite.")
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(32)
        .onAppear { if selection == nil { selection = entries.first?.id } }
        .onChange(of: selection) { _, _ in showRaw = false; model.stopPlayback() }
        .onChange(of: entries.map(\.id)) { _, ids in
            if selection.map({ !ids.contains($0) }) ?? true { selection = ids.first }
        }
        .onDisappear { model.stopPlayback() }
        .confirmationDialog("Delete this recording?", isPresented: Binding(
            get: { deletion != nil }, set: { if !$0 { deletion = nil } }
        ), titleVisibility: .visible) {
            Button("Delete recording", role: .destructive) {
                if let entry = deletion { model.stopPlayback(); model.deleteHistory(entry) }
                deletion = nil
            }
        } message: { Text("Its saved text and retained audio will be deleted. This cannot be undone.") }
        .confirmationDialog("Delete all history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete all history", role: .destructive) { model.stopPlayback(); model.clearHistory() }
        } message: { Text("All saved entries and their retained audio will be deleted. Export first if you need a copy.") }
    }

    private func historyDetail(_ entry: HistoryEntry) -> some View {
        Surface {
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.targetApp.isEmpty ? "Recording" : entry.targetApp).font(.system(size: 18, weight: .semibold))
                Text(entry.createdAt.formatted(date: .long, time: .shortened))
                    .foregroundStyle(WhisperAppearance.secondary)
                Text("\(WhisperAppearance.duration(entry.duration)) audio  /  \(entry.wordCount) words  /  \(entry.status.rawValue.capitalized)")
                    .font(.system(size: 11)).foregroundStyle(WhisperAppearance.secondary)
                if entry.isCommand { Label("Voice command", systemImage: "wand.and.stars").font(.system(size: 11)) }
                Text(entry.inserted ? "Inserted into the target app" : "Not automatically inserted")
                    .font(.system(size: 11)).foregroundStyle(WhisperAppearance.secondary)
            }
            if let error = entry.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).font(.system(size: 12)).textSelection(.enabled)
            }
            Picker("Transcript version", selection: $showRaw) {
                Text("Edited").tag(false)
                Text("Raw").tag(true)
            }.pickerStyle(.segmented)
            Text((showRaw ? entry.rawText : entry.text).isEmpty ? "No text in this version." : (showRaw ? entry.rawText : entry.text))
                .textSelection(.enabled).lineSpacing(5).frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            ViewThatFits(in: .horizontal) {
                HStack { textActions(entry) }
                VStack(alignment: .leading, spacing: 10) { textActions(entry) }
            }
            if showRaw && !entry.rawText.isEmpty {
                Button("Use raw text as result") { model.useRawText(entry) }
            }
            Divider()
            if entry.audioFileName != nil {
                ViewThatFits(in: .horizontal) {
                    HStack { audioActions(entry) }
                    VStack(alignment: .leading, spacing: 10) { audioActions(entry) }
                }
            } else {
                Text("Audio was not retained. Playback and audio retry are unavailable.")
                    .font(.system(size: 11)).foregroundStyle(WhisperAppearance.secondary)
            }
            if let original = entry.originalText, !original.isEmpty {
                DisclosureGroup("Original selection") { Text(original).textSelection(.enabled).padding(.top, 8) }
            }
            Button("Delete recording...", role: .destructive) { deletion = entry }
        }
    }

    @ViewBuilder private func textActions(_ entry: HistoryEntry) -> some View {
        let text = showRaw ? entry.rawText : entry.text
        Button { model.copyText(text) } label: { Label("Copy", systemImage: "doc.on.doc") }.disabled(text.isEmpty)
        Button { rewrite(text) } label: { Label("Rewrite in Scratchpad", systemImage: "wand.and.stars") }.disabled(text.isEmpty)
    }

    @ViewBuilder private func audioActions(_ entry: HistoryEntry) -> some View {
        Button { model.playAudio(entry) } label: { Label("Play", systemImage: "play.fill") }
        Button(action: model.stopPlayback) { Image(systemName: "stop.fill") }.accessibilityLabel("Stop playback").help("Stop playback")
        Button("Retry audio") { model.retry(entry) }.disabled(!model.hasAPIKey || model.isBusy)
    }
}

private enum LibraryKind: String, Identifiable {
    case dictionary = "Dictionary", snippets = "Snippets", appStyles = "App Styles", transforms = "Transforms"
    var id: Self { self }
    var singular: String {
        switch self {
        case .dictionary: return "term"
        case .snippets: return "snippet"
        case .appStyles: return "app style"
        case .transforms: return "transform"
        }
    }
    var subtitle: String {
        switch self {
        case .dictionary: return "Teach WhisperType the names and terms you use."
        case .snippets: return "Expand a spoken trigger into reusable text."
        case .appStyles: return "Choose how your writing sounds in each app."
        case .transforms: return "Reusable instructions for rewriting selected text."
        }
    }
    var symbol: String {
        switch self {
        case .dictionary: return "character.book.closed"
        case .snippets: return "text.badge.plus"
        case .appStyles: return "app.dashed"
        case .transforms: return "wand.and.stars"
        }
    }
}

private struct LibraryDraft: Identifiable {
    var id = UUID()
    var name = ""
    var value = ""
    var instructions = ""
    var style: WritingStyle = .natural
}

@MainActor
private struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    let kind: LibraryKind
    @State private var search = ""
    @State private var selection: UUID?
    @State private var draft: LibraryDraft?
    @State private var deleting: LibraryDraft?
    @State private var selectionTransform: CustomTransform?

    private var allRows: [LibraryDraft] {
        let all: [LibraryDraft]
        switch kind {
        case .dictionary:
            all = model.library.vocabulary.map { LibraryDraft(id: $0.id, name: $0.term, value: $0.heardAs) }
        case .snippets:
            all = model.library.snippets.map { LibraryDraft(id: $0.id, name: $0.trigger, value: $0.expansion) }
        case .appStyles:
            all = model.library.appRules.map { LibraryDraft(id: $0.id, name: $0.appName, value: $0.bundleID, instructions: $0.instructions, style: $0.style) }
        case .transforms:
            all = model.library.transforms.map { LibraryDraft(id: $0.id, name: $0.name, value: $0.instruction) }
        }
        return all
    }

    private var rows: [LibraryDraft] {
        allRows.filter { search.isEmpty || "\($0.name) \($0.value) \($0.instructions)".localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeading(title: kind.rawValue, subtitle: kind.subtitle)
                HStack(spacing: 12) {
                    TextField("Search \(kind.rawValue.lowercased())", text: $search)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Search \(kind.rawValue)")
                    Menu {
                        Button("Import library JSON...", action: model.importLibrary)
                        Button("Export library JSON...", action: model.exportLibrary)
                    } label: { Image(systemName: "square.and.arrow.up.on.square") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Import or export library")
                    Button { draft = LibraryDraft() } label: { Label("Add \(kind.singular)", systemImage: "plus") }
                        .buttonStyle(.borderedProminent).fixedSize().keyboardShortcut("n", modifiers: .command)
                }
                if kind == .transforms {
                    Surface {
                        Label("Use a transform where you write", systemImage: "cursorarrow.click.2").fontWeight(.semibold)
                        Text("For Polish, select text in another app and press Control + Option + P. For a custom transform, select it below and choose Use on selection. You will be asked to switch back to the target app before it runs.")
                            .foregroundStyle(WhisperAppearance.secondary)
                        Text("Selected text is sent to OpenAI. Voice commands use Control + Option + Command.")
                            .font(.system(size: 11)).foregroundStyle(WhisperAppearance.secondary)
                    }
                }
                if rows.isEmpty {
                    Surface {
                        EmptyState(symbol: search.isEmpty ? kind.symbol : "magnifyingglass",
                                   title: search.isEmpty ? "No \(kind.rawValue.lowercased()) yet" : "No matches",
                                   message: search.isEmpty ? "Add a \(kind.singular) to make WhisperType work better for you." : "Try a different search.")
                    }
                } else {
                    List(selection: $selection) {
                        ForEach(rows) { row in
                            HStack(alignment: .top, spacing: 16) {
                                Image(systemName: kind.symbol).foregroundStyle(WhisperAppearance.action)
                                    .frame(width: 20).padding(.top, 2).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(row.name).fontWeight(.semibold)
                                    Text(row.value.isEmpty ? "No alternate pronunciation" : row.value)
                                        .foregroundStyle(WhisperAppearance.secondary).lineLimit(2)
                                    if kind == .appStyles {
                                        Text(row.style.title).font(.system(size: 11)).foregroundStyle(WhisperAppearance.action)
                                    }
                                }
                                Spacer()
                                Button { selection = row.id; draft = row } label: { Image(systemName: "pencil") }
                                    .buttonStyle(.borderless).accessibilityLabel("Edit \(row.name)").help("Edit \(row.name)")
                            }
                            .padding(.vertical, 12).tag(row.id)
                            .contextMenu {
                                Button("Edit...") { draft = row }
                                if kind == .transforms {
                                    Button("Use on selection...") {
                                        selectionTransform = CustomTransform(id: row.id, name: row.name, instruction: row.value)
                                    }.disabled(!model.hasAPIKey || model.isTransforming)
                                }
                                Divider()
                                Button("Delete...", role: .destructive) { deleting = row }
                            }
                        }
                    }
                    .listStyle(.inset).scrollContentBackground(.hidden)
                    .frame(height: min(max(CGFloat(rows.count) * 90, 160), 400))
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(WhisperAppearance.line, lineWidth: 1))
                    .accessibilityLabel(kind.rawValue)
                    .onDeleteCommand { deleting = rows.first { $0.id == selection } }
                    .onKeyPress(.return) {
                        guard let row = rows.first(where: { $0.id == selection }) else { return .ignored }
                        draft = row
                        return .handled
                    }
                    if let row = rows.first(where: { $0.id == selection }) {
                        Surface(title: row.name) {
                            Text(row.value.isEmpty ? "No alternate pronunciation" : row.value).textSelection(.enabled).lineSpacing(4)
                            if kind == .appStyles {
                                LabeledContent("Writing style", value: row.style.title)
                                if !row.instructions.isEmpty { Text(row.instructions).textSelection(.enabled) }
                            }
                            HStack(spacing: 12) {
                                Button("Edit...") { draft = row }
                                if kind == .transforms {
                                    Button("Use on selection...") {
                                        selectionTransform = CustomTransform(id: row.id, name: row.name, instruction: row.value)
                                    }.disabled(!model.hasAPIKey || model.isTransforming)
                                }
                                Spacer()
                                Button("Delete...", role: .destructive) { deleting = row }
                            }
                        }
                    }
                }
                Text("Library JSON includes dictionary terms, snippets, app styles, and transforms. Review imported instructions before use.")
                    .font(.system(size: 11)).foregroundStyle(WhisperAppearance.secondary)
            }.padding(32).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }
        .id(kind)
        .sheet(item: $draft) { item in
            LibraryEditor(kind: kind, initial: item, isNew: !allRows.contains { $0.id == item.id }, existingNames: allRows.filter { $0.id != item.id }.map {
                kind == .appStyles ? $0.value : $0.name
            }) { save($0) }
        }
        .sheet(item: $selectionTransform) { transform in
            SelectionTransformView(transform: transform).environmentObject(model)
        }
        .confirmationDialog("Delete this \(kind.singular)?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let id = deleting?.id else { return }
                switch kind {
                case .dictionary: model.library.vocabulary.removeAll { $0.id == id }
                case .snippets: model.library.snippets.removeAll { $0.id == id }
                case .appStyles: model.library.appRules.removeAll { $0.id == id }
                case .transforms: model.library.transforms.removeAll { $0.id == id }
                }
                if selection == id { selection = nil }
                deleting = nil
            }
        } message: { Text("This removes it from your library. Existing history stays unchanged.") }
    }

    private func save(_ item: LibraryDraft) {
        switch kind {
        case .dictionary:
            let value = VocabularyEntry(id: item.id, term: item.name, heardAs: item.value)
            if let index = model.library.vocabulary.firstIndex(where: { $0.id == item.id }) { model.library.vocabulary[index] = value }
            else { model.library.vocabulary.append(value) }
        case .snippets:
            let value = Snippet(id: item.id, trigger: item.name, expansion: item.value)
            if let index = model.library.snippets.firstIndex(where: { $0.id == item.id }) { model.library.snippets[index] = value }
            else { model.library.snippets.append(value) }
        case .appStyles:
            let value = AppRule(id: item.id, bundleID: item.value, appName: item.name, style: item.style, instructions: item.instructions)
            if let index = model.library.appRules.firstIndex(where: { $0.id == item.id }) { model.library.appRules[index] = value }
            else { model.library.appRules.append(value) }
        case .transforms:
            let value = CustomTransform(id: item.id, name: item.name, instruction: item.value)
            if let index = model.library.transforms.firstIndex(where: { $0.id == item.id }) { model.library.transforms[index] = value }
            else { model.library.transforms.append(value) }
        }
        search = ""
        selection = item.id
    }
}

private struct LibraryEditor: View {
    @Environment(\.dismiss) private var dismiss
    let kind: LibraryKind
    let isNew: Bool
    let existingNames: [String]
    let save: (LibraryDraft) -> Void
    @State private var draft: LibraryDraft
    @FocusState private var nameFocused: Bool

    init(kind: LibraryKind, initial: LibraryDraft, isNew: Bool, existingNames: [String], save: @escaping (LibraryDraft) -> Void) {
        self.kind = kind
        self.isNew = isNew
        self.existingNames = existingNames
        self.save = save
        _draft = State(initialValue: initial)
    }

    private var validation: String? {
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a \(kind == .dictionary ? "term" : "name or trigger") to save." }
        if kind != .dictionary && draft.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return kind == .appStyles ? "Enter the app's bundle identifier." : "Enter \(kind == .snippets ? "the expansion" : "an instruction") to save."
        }
        let identity = (kind == .appStyles ? draft.value : draft.name).trimmingCharacters(in: .whitespacesAndNewlines)
        if existingNames.contains(where: { $0.caseInsensitiveCompare(identity) == .orderedSame }) { return "This \(kind.singular) already exists. Choose a different value." }
        if kind == .appStyles && (!identity.contains(".") || identity.contains(where: \.isWhitespace)) { return "Use a bundle identifier such as com.apple.mail." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("\(isNew ? "Add" : "Edit") \(kind.singular)").font(.system(size: 22, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    EditorField(title: kind == .dictionary ? "Term" : kind == .snippets ? "Spoken trigger" : "Name") {
                        TextField(kind == .dictionary ? "e.g. WhisperType" : "Name", text: $draft.name)
                            .focused($nameFocused)
                    }
                    switch kind {
                    case .dictionary:
                        EditorField(title: "Heard as (optional)") { TextField("e.g. whisper type", text: $draft.value) }
                        Text("The correct spelling goes in Term. Add a common mishearing if needed.").foregroundStyle(WhisperAppearance.secondary)
                    case .snippets:
                        EditorField(title: "Expansion") { DraftTextEditor(text: $draft.value, label: "Snippet expansion") }
                        Text("Use a distinctive trigger to avoid expanding ordinary speech.").foregroundStyle(WhisperAppearance.secondary)
                    case .appStyles:
                        EditorField(title: "Bundle identifier") { TextField("com.apple.mail", text: $draft.value) }
                        Picker("Writing style", selection: $draft.style) {
                            ForEach(WritingStyle.allCases) { Text($0.title).tag($0) }
                        }
                        EditorField(title: "App instructions (optional)") { DraftTextEditor(text: $draft.instructions, label: "App instructions") }
                    case .transforms:
                        EditorField(title: "Instruction") { DraftTextEditor(text: $draft.value, label: "Transform instruction") }
                        Text("Describe the edit to make. For example: shorten the text without removing names or action items.")
                            .foregroundStyle(WhisperAppearance.secondary)
                    }
                }
            }
            if let validation { Text(validation).font(.system(size: 11)).foregroundStyle(WhisperAppearance.secondary) }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if kind == .dictionary || kind == .appStyles { draft.value = draft.value.trimmingCharacters(in: .whitespacesAndNewlines) }
                    save(draft)
                    dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(validation != nil)
            }
        }
        .font(.system(size: 13)).textFieldStyle(.roundedBorder)
        .padding(32).frame(width: 540, height: kind == .dictionary ? 350 : 550)
        .background(WhisperAppearance.canvas).foregroundStyle(WhisperAppearance.text)
        .tint(WhisperAppearance.action).preferredColorScheme(.light)
        .onAppear { nameFocused = true }
        .interactiveDismissDisabled()
    }
}

private struct EditorField<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, weight: .medium))
            content.accessibilityLabel(title)
        }
    }
}

private struct DraftTextEditor: View {
    @Binding var text: String
    let label: String
    var body: some View {
        TextEditor(text: $text).font(.system(size: 13)).scrollContentBackground(.hidden)
            .padding(8).frame(minHeight: 120)
            .background(.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(WhisperAppearance.line, lineWidth: 1))
            .accessibilityLabel(label)
    }
}

@MainActor
private struct SelectionTransformView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let transform: CustomTransform
    @State private var armed = false
    @State private var launching = false
    @State private var message = ""
    @State private var launchTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(transform.name, systemImage: "wand.and.stars").font(.system(size: 22, weight: .semibold))
            Text("Run on a selection in another app").fontWeight(.semibold)
            Text("First select editable text in the target app. Return here, arm the transform, then switch back to that app. WhisperType will run once on its current selection, not on text in this window.")
                .foregroundStyle(WhisperAppearance.secondary)
            Text("For the default Polish action, you can instead keep the target app focused and press Control + Option + P.")
                .foregroundStyle(WhisperAppearance.secondary)
            Text("The selected text and this instruction will be sent to OpenAI. Check the target selection before arming.")
                .font(.system(size: 11)).foregroundStyle(WhisperAppearance.secondary)
            if armed { Label("Armed. Switch to the target app within 30 seconds.", systemImage: "arrow.up.forward.app") }
            if !message.isEmpty { Text(message).foregroundStyle(WhisperAppearance.secondary) }
            HStack {
                Button("Cancel", role: .cancel) { launchTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(armed || launching ? "Waiting for target app" : "Run when I switch apps") { message = ""; armed = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(armed || launching || !model.hasAPIKey || !model.accessibilityGranted || model.isTransforming)
            }
            if !model.accessibilityGranted { Text("Enable Accessibility in Settings to read and replace a selection.").foregroundStyle(.red) }
        }
        .font(.system(size: 13)).padding(32).frame(width: 540)
        .background(WhisperAppearance.canvas).foregroundStyle(WhisperAppearance.text)
        .tint(WhisperAppearance.action).preferredColorScheme(.light)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) { notification in
            guard armed, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            armed = false
            launching = true
            // Activation precedes some apps restoring their focused AX element.
            launchTask = Task { @MainActor in
                defer { launching = false }
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                    message = "Focus changed before the transform ran. Arm it again when ready."
                    return
                }
                model.runTransform(transform)
                dismiss()
            }
        }
        .task(id: armed) {
            guard armed else { return }
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            armed = false
            message = "No app switch detected. Nothing was sent. You can arm the transform again."
        }
        .onDisappear { launchTask?.cancel() }
    }
}

@MainActor
private struct ScratchpadView: View {
    @EnvironmentObject var model: AppModel
    @State private var transformID: UUID?
    @State private var confirmClear = false
    private var transform: CustomTransform? {
        model.library.transforms.first { $0.id == transformID } ?? model.library.transforms.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeading(title: "Scratchpad", subtitle: "A place to write, paste, and try a different version.")
                Surface {
                    HStack {
                        Label("Your text", systemImage: "square.and.pencil").fontWeight(.semibold)
                        Spacer()
                        Text("\(model.scratchpad.split(whereSeparator: \.isWhitespace).count) words")
                            .font(.system(size: 11)).foregroundStyle(WhisperAppearance.secondary).monospacedDigit()
                    }
                    TextEditor(text: $model.scratchpad)
                        .font(.system(size: 14)).lineSpacing(5).scrollContentBackground(.hidden)
                        .frame(minHeight: 280).accessibilityLabel("Scratchpad text")
                        .disabled(model.isTransforming)
                        .overlay(alignment: .topLeading) {
                            if model.scratchpad.isEmpty {
                                Text("Write or paste something here...").foregroundStyle(WhisperAppearance.secondary)
                                    .padding(.horizontal, 5).padding(.top, 1).allowsHitTesting(false).accessibilityHidden(true)
                            }
                        }
                    Divider()
                    HStack(spacing: 12) {
                        Button { model.copyText(model.scratchpad) } label: { Label("Copy text", systemImage: "doc.on.doc") }
                            .disabled(model.scratchpad.isEmpty)
                        Spacer()
                        Button("Clear...", role: .destructive) { confirmClear = true }
                            .disabled(model.scratchpad.isEmpty || model.isTransforming)
                    }
                }
                Surface(title: "Transform") {
                    if model.library.transforms.isEmpty {
                        Text("Add a transform in Transforms to run it here.").foregroundStyle(WhisperAppearance.secondary)
                    } else {
                        HStack(spacing: 14) {
                            Picker("Transform", selection: Binding(
                                get: { transform?.id }, set: { transformID = $0 }
                            )) {
                                ForEach(model.library.transforms) { Text($0.name).tag(Optional($0.id)) }
                            }.labelsHidden().accessibilityLabel("Scratchpad transform").disabled(model.isTransforming)
                            Button {
                                if let transform { model.transformScratchpad(transform) }
                            } label: {
                                Label(model.isTransforming ? "Transforming..." : "Run transform", systemImage: "wand.and.stars")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isTransforming || !model.hasAPIKey || model.scratchpad.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        if let transform { Text(transform.instruction).foregroundStyle(WhisperAppearance.secondary).textSelection(.enabled) }
                    }
                    Text("Typing stays on this Mac until you run a transform. Run sends the text to OpenAI and replaces this draft with the result. Results are saved to history when history is enabled.")
                        .font(.system(size: 11)).foregroundStyle(WhisperAppearance.secondary)
                    if !model.hasAPIKey {
                        Button("Connect an API key to run transforms") { model.showSetup = true }.buttonStyle(.link)
                    }
                }
            }.padding(32).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }
        .confirmationDialog("Clear the Scratchpad?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear text", role: .destructive) { model.scratchpad = "" }
        } message: { Text("This clears the current draft. Saved history is not affected.") }
    }
}

@MainActor
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var embedded = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            if !embedded { ErrorNotice() }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    PageHeading(title: "Settings", subtitle: "Make dictation fit the way you work. Changes save automatically.")
                    Surface(title: "OpenAI connection") { APIKeyFields() }
                    Surface(title: "Permissions") { PermissionFields() }
                    recordingSettings
                    writingSettings
                    shortcutSettings
                    insertionSettings
                    storageSettings
                    Surface(title: "General") {
                        Toggle("Launch WhisperType at login", isOn: $model.settings.launchAtLogin)
                        Toggle("Play recording sounds", isOn: $model.settings.soundEffects)
                    }
                    PrivacyNote()
                }.padding(32).frame(maxWidth: 900).frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 580, idealWidth: 720, minHeight: 480, idealHeight: 680)
        .font(.system(size: 13)).foregroundStyle(WhisperAppearance.text)
        .background(WhisperAppearance.canvas).tint(WhisperAppearance.action).preferredColorScheme(.light)
        .textFieldStyle(.roundedBorder)
        .onAppear { model.refreshPermissions(); model.refreshMicrophones() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.refreshPermissions() } }
    }

    private var recordingSettings: some View {
        Surface(title: "Recording") {
            Picker("Processing", selection: $model.settings.processingMode) {
                ForEach(ProcessingMode.allCases) { Text($0.title).tag($0) }
            }
            Text(model.settings.processingMode == .accurate ? "Upload audio after recording stops for a final transcript." :
                    "Stream microphone audio to OpenAI while you speak. Live text is provisional until the recording finishes.")
                .font(.system(size: 11)).foregroundStyle(WhisperAppearance.secondary)
            Picker("While a result is processing", selection: $model.settings.pipelineEnabled) {
                Text("Queue new recordings").tag(true)
                Text("Wait before recording again").tag(false)
            }
            HStack {
                Picker("Microphone", selection: $model.settings.microphoneID) {
                    Text("System default").tag("")
                    if !model.settings.microphoneID.isEmpty && !model.microphones.contains(where: { $0.id == model.settings.microphoneID }) {
                        Text("Selected microphone (unavailable)").tag(model.settings.microphoneID)
                    }
                    ForEach(model.microphones) { Text($0.name).tag($0.id) }
                }
                Button(action: model.refreshMicrophones) { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Refresh microphones").help("Refresh microphones")
            }
            EditorField(title: "Spoken language") {
                HStack {
                    TextField("auto, en, hi, te...", text: $model.settings.language)
                    Menu("Common languages") {
                        Button("Auto-detect") { model.settings.language = "auto" }
                        Button("English (en)") { model.settings.language = "en" }
                        Button("Hindi (hi)") { model.settings.language = "hi" }
                        Button("Telugu (te)") { model.settings.language = "te" }
                        Button("Spanish (es)") { model.settings.language = "es" }
                        Button("French (fr)") { model.settings.language = "fr" }
                        Button("German (de)") { model.settings.language = "de" }
                        Button("Japanese (ja)") { model.settings.language = "ja" }
                    }.fixedSize()
                }
            }
            Toggle("Stop automatically after silence", isOn: $model.settings.silenceAutoStop)
            if model.settings.silenceAutoStop {
                Stepper(value: $model.settings.silenceSeconds, in: 2...60, step: 1) {
                    Text("Silence before stopping: \(Int(model.settings.silenceSeconds)) seconds")
                }
            }
            Stepper(value: $model.settings.maxRecordingSeconds, in: 30...1200, step: 30) {
                Text("Maximum recording: \(WhisperAppearance.duration(model.settings.maxRecordingSeconds))")
            }
            DisclosureGroup("Model identifiers") {
                VStack(alignment: .leading, spacing: 14) {
                    EditorField(title: "Transcription model") { TextField("Transcription model", text: $model.settings.transcriptionModel) }
                    EditorField(title: "Realtime model") { TextField("Realtime model", text: $model.settings.realtimeModel) }
                    EditorField(title: "Rewrite model") { TextField("Rewrite model", text: $model.settings.rewriteModel) }
                    Text("Availability depends on your OpenAI account. A saved identifier does not verify model access.")
                        .font(.system(size: 11)).foregroundStyle(WhisperAppearance.secondary)
                }.padding(.top, 12)
            }
        }
    }

    private var writingSettings: some View {
        Surface(title: "Writing") {
            Picker("Cleanup", selection: $model.settings.cleanup) {
                ForEach(CleanupLevel.allCases) { Text($0.title).tag($0) }
            }
            Picker("Default style", selection: $model.settings.style) {
                ForEach(WritingStyle.allCases) { Text($0.title).tag($0) }
            }
            EditorField(title: "Translate into (optional)") {
                TextField("Leave blank to preserve the spoken language", text: $model.settings.translationLanguage)
            }
            Text("Use a language name or code, such as English or en. Translation and cleanup use cloud text processing.")
                .font(.system(size: 11)).foregroundStyle(WhisperAppearance.secondary)
            EditorField(title: "Custom instructions") {
                DraftTextEditor(text: $model.settings.customInstructions, label: "Global writing instructions")
            }
        }
    }

    private var shortcutSettings: some View {
        Surface(title: "Keyboard shortcuts") {
            Picker("Hold-to-talk preset", selection: $model.settings.shortcut) {
                ForEach(ShortcutPreset.allCases) { Text($0.title).tag($0) }
            }
            ShortcutRows(preset: model.settings.shortcut)
            if model.settings.shortcut == .fn {
                Text("Before using Fn / Globe, open macOS System Settings > Keyboard and set 'Press Globe key to' to 'Do Nothing'. Disable any Fn-based Dictation shortcut that conflicts.")
                    .font(.system(size: 12)).foregroundStyle(WhisperAppearance.secondary)
            }
            HStack {
                Label(model.hotkeysReady ? "Global shortcuts are active" : "Global shortcuts are not active",
                      systemImage: model.hotkeysReady ? "checkmark.circle" : "exclamationmark.circle")
                    .foregroundStyle(model.hotkeysReady ? WhisperAppearance.action : WhisperAppearance.secondary)
                Spacer()
                Button("Restart shortcuts", action: model.applySettings)
            }
        }
    }

    private var insertionSettings: some View {
        Surface(title: "Insertion and context") {
            Toggle("Insert finished text into the target app", isOn: $model.settings.autoInsert)
            Toggle("Restore clipboard after automatic paste", isOn: $model.settings.restoreClipboard)
            Toggle("Include surrounding app text as context", isOn: $model.settings.contextEnabled)
            Text("Context is optional and off by default. When enabled, nearby text from the focused field may be sent to OpenAI to improve results. Commands and selection transforms send the text you select even when context is off.")
                .font(.system(size: 11)).foregroundStyle(WhisperAppearance.secondary)
            Text("Insertion needs Accessibility access and a supported editable field. If the target changes, copy the result from History instead.")
                .font(.system(size: 11)).foregroundStyle(WhisperAppearance.secondary)
        }
    }

    private var storageSettings: some View {
        Surface(title: "History and storage") {
            Toggle("Keep transcription history", isOn: $model.settings.retainHistory)
            Toggle("Retain audio for playback and retry", isOn: $model.settings.retainAudio)
                .disabled(!model.settings.retainHistory)
            Stepper(value: $model.settings.retentionDays, in: 1...365) {
                Text("Retain history for \(model.settings.retentionDays) days")
            }.disabled(!model.settings.retainHistory)
            Text("Turning off history deletes saved history and its audio. Turning off audio retention deletes saved recordings. These changes do not undo cloud requests; exports are separate copies.")
                .font(.system(size: 11)).foregroundStyle(WhisperAppearance.secondary)
            HStack {
                Button("Open data folder", action: model.openDataFolder)
                Button("Export history...", action: model.exportHistory).disabled(model.history.isEmpty)
            }
        }
    }
}

@MainActor
private struct APIKeyFields: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmRemove = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(model.hasAPIKey ? "API key saved in Keychain" : "Add an OpenAI API key to get started",
                  systemImage: model.hasAPIKey ? "checkmark.circle" : "key")
                .foregroundStyle(WhisperAppearance.action)
            SecureField(model.hasAPIKey ? "Enter a replacement API key" : "OpenAI API key", text: $model.apiKeyDraft)
                .textFieldStyle(.roundedBorder).accessibilityLabel("OpenAI API key")
                .onSubmit { if !model.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { model.saveAPIKey() } }
            HStack {
                Button(model.hasAPIKey ? "Update key" : "Save key", action: model.saveAPIKey)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if model.hasAPIKey {
                    Button("Remove key...", role: .destructive) { confirmRemove = true }
                }
                Spacer()
                Link("Manage API keys", destination: URL(string: "https://platform.openai.com/api-keys")!)
            }
            Text("The key is stored in macOS Keychain, not in library exports. Saving a key does not verify account credit or model access. OpenAI API billing is separate from a ChatGPT subscription.")
                .font(.system(size: 11)).foregroundStyle(WhisperAppearance.secondary)
            PrivacyNote()
        }
        .confirmationDialog("Remove the saved API key?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove key", role: .destructive, action: model.removeAPIKey)
        } message: { Text("New cloud requests will need a key. Your library and history will remain on this Mac.") }
        .onDisappear { model.apiKeyDraft = "" }
    }
}

@MainActor
private struct PermissionFields: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            permission("Microphone", detail: "Record your voice when you start dictation.", granted: model.microphoneGranted,
                       action: model.requestMicrophonePermission)
            Divider()
            permission("Accessibility", detail: "Use global shortcuts and insert into supported text fields.", granted: model.accessibilityGranted,
                       action: model.requestAccessibilityPermission)
            Divider()
            permission("Input Monitoring", detail: "Detect shortcut keys globally, not the text you type.", granted: model.inputMonitoringGranted,
                       action: model.requestInputMonitoringPermission)
            Text("After enabling access in System Settings, refresh permissions. macOS may require you to quit and reopen WhisperType.")
                .font(.system(size: 11)).foregroundStyle(WhisperAppearance.secondary)
            Button("Refresh permissions", action: model.refreshPermissions)
        }
    }

    private func permission(_ title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? WhisperAppearance.action : WhisperAppearance.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.system(size: 11)).foregroundStyle(WhisperAppearance.secondary)
            }
            Spacer(minLength: 8)
            if granted { Text("Allowed").font(.system(size: 11)).foregroundStyle(WhisperAppearance.action) }
            else { Button("Allow...", action: action).accessibilityLabel("Allow \(title)") }
        }
    }
}

@MainActor
private struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            ErrorNotice()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    PageHeading(title: "Set up WhisperType", subtitle: "Connect cloud transcription and choose which system access to allow.")
                    Surface(title: "1. Connect OpenAI") { APIKeyFields() }
                    Surface(title: "2. Allow system access") { PermissionFields() }
                    Surface(title: "3. Try dictation") {
                        Text("Focus a text field in another app, hold \(model.settings.shortcut.title), and speak. Release to finish. Use Control + Option + Space for hands-free recording and Escape to cancel.")
                            .foregroundStyle(WhisperAppearance.secondary)
                    }
                }.padding(32)
            }
            Divider()
            HStack {
                Text("You can change these choices in Settings.").font(.system(size: 11)).foregroundStyle(WhisperAppearance.secondary)
                Spacer()
                Button(model.hasAPIKey && model.microphoneGranted ? "Done" : "Set up later") { dismiss() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }.padding(20)
        }
        .frame(width: 650, height: 640).font(.system(size: 13))
        .background(WhisperAppearance.canvas).foregroundStyle(WhisperAppearance.text)
        .tint(WhisperAppearance.action).preferredColorScheme(.light)
        .onAppear { model.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshPermissions() }
    }
}

@MainActor
struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Text(model.isRecording ? "Recording \(WhisperAppearance.duration(model.elapsed))" : "WhisperType")
        if !model.statusMessage.isEmpty { Text(model.statusMessage) }
        if model.pendingCount > 0 { Text("\(model.pendingCount) pending") }
        Divider()
        Button("Open WhisperType", action: model.showMainWindow)
        Button(model.isRecording ? "Stop recording" : "Start recording", action: model.toggleRecording)
            .disabled(model.phase == .requestingPermission || model.phase == .stopping ||
                      (!model.isRecording && (!model.hasAPIKey || (model.isBusy && !model.settings.pipelineEnabled))))
        if model.phase != .idle { Button("Cancel recording", action: model.cancelRecording) }
        if model.pendingCount > 0 { Button("Cancel pending", action: model.cancelPending) }
        Divider()
        Button("Copy last result", action: model.copyLast).disabled(model.lastText.isEmpty)
        Button("Paste last result", action: model.pasteLast).disabled(model.lastText.isEmpty || !model.accessibilityGranted)
        Divider()
        Menu("Permissions") {
            Button(model.microphoneGranted ? "Microphone: Allowed" : "Allow Microphone...", action: model.requestMicrophonePermission)
                .disabled(model.microphoneGranted)
            Button(model.accessibilityGranted ? "Accessibility: Allowed" : "Allow Accessibility...", action: model.requestAccessibilityPermission)
                .disabled(model.accessibilityGranted)
            Button(model.inputMonitoringGranted ? "Input Monitoring: Allowed" : "Allow Input Monitoring...", action: model.requestInputMonitoringPermission)
                .disabled(model.inputMonitoringGranted)
            Divider()
            Button("Refresh permissions", action: model.refreshPermissions)
        }
        Button("Setup...") { model.showSetup = true; model.showMainWindow() }
        Divider()
        Button("Quit WhisperType") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }
}
