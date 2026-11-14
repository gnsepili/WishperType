import AppKit
import SwiftUI

@MainActor
final class RecordingOverlayController {
    private let panel: RecordingPanel

    init(model: AppModel) {
        panel = RecordingPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 96),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.title = "WhisperType recording"
        panel.contentView = OverlayHostingView(rootView: RecordingOverlayView().environmentObject(model))
        panel.setContentSize(NSSize(width: 360, height: 96))
        // The parent owns visibility; creating the controller never shows a panel.
    }

    func show() {
        if !panel.isVisible { refresh() }
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }

    func refresh() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - 180, y: frame.minY + 24))
    }
}

private final class RecordingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private struct RecordingOverlayView: View {
    @EnvironmentObject var model: AppModel
    private var title: String {
        switch model.phase {
        case .idle: return model.pendingCount > 0 ? "Processing" : "Ready"
        case .requestingPermission: return "Requesting microphone"
        case .recording: return "Listening"
        case .stopping: return "Finishing"
        }
    }
    private var preview: String {
        if model.isRecording && !model.liveTranscript.isEmpty { return String(model.liveTranscript.suffix(150)) }
        return model.statusMessage.isEmpty ? "Release your shortcut to finish" : model.statusMessage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: model.isRecording ? "mic.fill" : "waveform")
                    .font(.system(size: 16)).foregroundStyle(WhisperAppearance.mint).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(title).font(.system(size: 12, weight: .semibold))
                        Text(WhisperAppearance.duration(model.elapsed))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(WhisperAppearance.mint)
                            .accessibilityLabel("Elapsed \(WhisperAppearance.duration(model.elapsed))")
                    }
                    AudioLevelMeter(level: model.level, isActive: model.isRecording, dark: true)
                        .frame(width: 168, height: 12)
                }
                Spacer(minLength: 0)
                Button(action: model.stopRecording) {
                    Image(systemName: "stop.fill").font(.system(size: 11))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain).foregroundStyle(WhisperAppearance.ink)
                .background(WhisperAppearance.mint, in: RoundedRectangle(cornerRadius: 8))
                .disabled(!model.isRecording).opacity(model.isRecording ? 1 : 0.45)
                .accessibilityLabel("Stop recording").help("Stop recording")
                Button {
                    if model.phase == .idle { model.cancelPending() } else { model.cancelRecording() }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).frame(width: 24, height: 30)
                }
                .buttonStyle(.plain).foregroundStyle(Color.white.opacity(0.75))
                .accessibilityLabel(model.phase == .idle ? "Cancel pending processing" : "Cancel recording")
                .help("Cancel")
            }
            Text(preview).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.72))
                .lineLimit(1).truncationMode(.head).frame(maxWidth: .infinity, alignment: .leading)
                .help(preview)
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(width: 360, height: 96)
        .foregroundStyle(.white)
        .background(WhisperAppearance.ink, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .preferredColorScheme(.dark)
    }
}

struct AudioLevelMeter: View {
    let level: Float
    let isActive: Bool
    var dark = false
    private var normalizedLevel: Double { isActive && level.isFinite ? Double(min(max(level, 0), 1)) : 0 }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 3) {
                ForEach(0..<24, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Double(index) / 24 < normalizedLevel ?
                              (dark ? WhisperAppearance.mint : WhisperAppearance.action) :
                                (dark ? Color.white.opacity(0.14) : WhisperAppearance.line))
                        .frame(maxWidth: .infinity)
                }
            }.frame(height: geometry.size.height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone level")
        .accessibilityValue("\(Int(normalizedLevel * 100)) percent")
    }
}
