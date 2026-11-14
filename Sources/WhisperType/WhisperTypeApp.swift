import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "WhisperType")
        model?.onShowMainWindow = { [weak self] in self?.showWindow() }
        model?.installOverlay()
        showWindow()
    }

    func showWindow() {
        guard let model else { return }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "WhisperType"
            window.contentView = NSHostingView(rootView: MainView().environmentObject(model))
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("WhisperTypeMain")
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
}

@main
struct WhisperTypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        delegate.model = model
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent().environmentObject(model)
        } label: {
            Label("WhisperType", systemImage: model.isRecording ? "mic.fill" : "waveform")
        }
        .menuBarExtraStyle(.menu)
        Settings { SettingsView().environmentObject(model).frame(width: 720, height: 680) }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About WhisperType") { model.showMainWindow() }
            }
        }
    }
}
