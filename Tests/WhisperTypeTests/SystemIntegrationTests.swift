import ApplicationServices
import Carbon
import Testing
import WhisperCore
@testable import WhisperType

@MainActor
struct SystemIntegrationTests {
    private let controlOption: CGEventFlags = [.maskControl, .maskAlternate]
    private let commandHold: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]

    // Private-state events are passed directly to the reducer, never posted.
    @discardableResult
    private func send(_ manager: HotkeyManager, _ type: CGEventType = .flagsChanged,
                      flags: CGEventFlags = [], key: Int = 0, repeatKey: Bool = false) throws -> Bool {
        let source = try #require(CGEventSource(stateID: .privateState))
        let event = try #require(CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key),
                                        keyDown: type != .keyUp))
        event.type = type
        event.flags = flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
        return manager.handle(type, event: event)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    @Test func defaultControlOptionHoldWaits120msThenEndsOnRelease() async throws {
        var actions: [HotkeyAction] = []
        var beganAt: ContinuousClock.Instant?
        let manager = HotkeyManager {
            actions.append($0)
            if $0 == .beginDictation { beganAt = .now }
        }
        defer { manager.stop() }

        let pressedAt = ContinuousClock.now
        #expect(try !send(manager, flags: controlOption))
        #expect(actions.isEmpty)
        try await waitUntil { beganAt != nil }
        #expect(pressedAt.duration(to: try #require(beganAt)) >= .milliseconds(120))
        #expect(actions == [.beginDictation])
        #expect(try !send(manager, flags: .maskControl))
        #expect(actions == [.beginDictation, .endDictation])
        try send(manager)
        #expect(actions == [.beginDictation, .endDictation])
    }

    @Test func shortHoldNeverBegins() async throws {
        var actions: [HotkeyAction] = []
        let manager = HotkeyManager { actions.append($0) }
        defer { manager.stop() }

        try send(manager, flags: controlOption)
        try send(manager)
        try await Task.sleep(for: .milliseconds(200))
        #expect(actions.isEmpty)
    }

    @Test func quickToggleSurvivesModifierReleaseAndSecondPressStopsIt() async throws {
        var actions: [HotkeyAction] = []
        let manager = HotkeyManager { actions.append($0) }
        defer { manager.stop() }

        try send(manager, flags: controlOption)
        #expect(try send(manager, .keyDown, flags: controlOption, key: kVK_Space))
        #expect(try send(manager, .keyUp, key: kVK_Space))
        manager.isActive = true
        try send(manager)
        try send(manager, flags: controlOption)
        try await Task.sleep(for: .milliseconds(200))
        #expect(actions == [.toggleDictation])
        #expect(try send(manager, .keyDown, flags: controlOption, key: kVK_Space))
        #expect(try send(manager, .keyUp, flags: controlOption, key: kVK_Space))
        try send(manager)
        #expect(actions == [.toggleDictation, .toggleDictation])
    }

    @Test func slowToggleLatchesExistingHoldWithoutTogglingItOff() async throws {
        var actions: [HotkeyAction] = []
        let manager = HotkeyManager { actions.append($0) }
        defer { manager.stop() }

        try send(manager, flags: controlOption)
        try await waitUntil { !actions.isEmpty }
        manager.isActive = true
        #expect(try send(manager, .keyDown, flags: controlOption, key: kVK_Space))
        #expect(try send(manager, .keyUp, flags: controlOption, key: kVK_Space))
        try send(manager, flags: .maskAlternate)
        try send(manager)
        try send(manager, flags: controlOption)
        try await Task.sleep(for: .milliseconds(200))
        #expect(actions == [.beginDictation])
        try send(manager, .keyDown, flags: controlOption, key: kVK_Space)
        try send(manager, .keyUp, key: kVK_Space)
        try send(manager)
        #expect(actions == [.beginDictation, .toggleDictation])
    }

    @Test func commandPrefixDisambiguatesBeforeDictationBegins() async throws {
        var actions: [HotkeyAction] = []
        let manager = HotkeyManager { actions.append($0) }
        defer { manager.stop() }

        try send(manager, flags: controlOption)
        try send(manager, flags: commandHold)
        #expect(actions.isEmpty)
        try await waitUntil { !actions.isEmpty }
        #expect(actions == [.beginCommand])
        try send(manager)
        #expect(actions == [.beginCommand, .endCommand])
    }

    @Test func commandUpgradeCancelsBeforeBeginAndDoesNotRestartDictation() async throws {
        var actions: [HotkeyAction] = []
        let manager = HotkeyManager { actions.append($0) }
        defer { manager.stop() }

        try send(manager, flags: controlOption)
        try await waitUntil { !actions.isEmpty }
        manager.isActive = true
        try send(manager, flags: commandHold)
        #expect(actions == [.beginDictation, .cancelForCommandUpgrade])
        try await waitUntil { actions.count == 3 }
        #expect(actions == [.beginDictation, .cancelForCommandUpgrade, .beginCommand])
        try send(manager, flags: controlOption)
        try await Task.sleep(for: .milliseconds(200))
        #expect(actions == [.beginDictation, .cancelForCommandUpgrade, .beginCommand, .endCommand])
        try send(manager)
        try send(manager, flags: controlOption)
        try await waitUntil { actions.count == 5 }
        #expect(actions.last == .beginDictation)
    }

    @Test func releasingPendingCommandFirstDoesNotStartDictation() async throws {
        var actions: [HotkeyAction] = []
        let manager = HotkeyManager { actions.append($0) }
        defer { manager.stop() }

        try send(manager, flags: commandHold)
        try send(manager, flags: controlOption)
        try await Task.sleep(for: .milliseconds(200))
        #expect(actions.isEmpty)
        try send(manager)
        try send(manager, flags: controlOption)
        try await waitUntil { !actions.isEmpty }
        #expect(actions == [.beginDictation])
    }

    @Test(arguments: [false, true])
    func unrelatedKeysPassThroughAndStopPendingOrActiveHold(active: Bool) async throws {
        var actions: [HotkeyAction] = []
        let manager = HotkeyManager { actions.append($0) }
        defer { manager.stop() }

        #expect(try !send(manager, .keyDown, key: kVK_ANSI_A))
        #expect(try !send(manager, .keyUp, key: kVK_ANSI_A))
        try send(manager, flags: controlOption)
        if active { try await waitUntil { !actions.isEmpty } }
        #expect(try !send(manager, .keyDown, flags: controlOption, key: kVK_ANSI_A))
        #expect(try !send(manager, .keyDown, flags: controlOption, key: kVK_ANSI_A, repeatKey: true))
        #expect(try !send(manager, .keyUp, key: kVK_ANSI_A))
        try send(manager, flags: controlOption)
        try await Task.sleep(for: .milliseconds(200))
        #expect(actions == (active ? [.beginDictation, .endDictation] : []))
    }

    @Test func escapeIsConsumedOnlyWhileActiveIncludingRepeatsAndKeyUp() throws {
        var actions: [HotkeyAction] = []
        let manager = HotkeyManager { actions.append($0) }
        defer { manager.stop() }

        #expect(try !send(manager, .keyDown, key: kVK_Escape))
        #expect(try !send(manager, .keyUp, key: kVK_Escape))
        #expect(actions.isEmpty)
        manager.isActive = true
        #expect(try send(manager, .keyDown, key: kVK_Escape))
        #expect(try send(manager, .keyDown, key: kVK_Escape, repeatKey: true))
        #expect(actions == [.cancel])
        #expect(try send(manager, .keyUp, key: kVK_Escape))
        #expect(try send(manager, .keyDown, key: kVK_Escape))
        manager.isActive = false
        #expect(try !send(manager, .keyDown, key: kVK_Escape, repeatKey: true))
        #expect(try !send(manager, .keyUp, key: kVK_Escape))
        #expect(try !send(manager, .keyDown, key: kVK_Escape))
        #expect(actions == [.cancel, .cancel])
    }

    @Test func shortcutRepeatsAreSwallowedWithoutDuplicateActions() throws {
        let shortcuts: [(Int, CGEventFlags, HotkeyAction)] = [
            (kVK_Space, controlOption, .toggleDictation),
            (kVK_ANSI_P, controlOption, .transformSelection),
            (kVK_ANSI_C, [.maskControl, .maskCommand], .copyLast),
            (kVK_ANSI_V, [.maskControl, .maskCommand], .pasteLast)
        ]
        for (key, flags, action) in shortcuts {
            var actions: [HotkeyAction] = []
            let manager = HotkeyManager { actions.append($0) }
            defer { manager.stop() }

            #expect(try send(manager, .keyDown, flags: flags, key: key, repeatKey: true))
            #expect(actions.isEmpty)
            #expect(try send(manager, .keyDown, flags: flags, key: key))
            #expect(try send(manager, .keyDown, flags: flags, key: key, repeatKey: true))
            #expect(try send(manager, .keyDown, flags: flags, key: key))
            #expect(actions == [action])
            #expect(try send(manager, .keyUp, key: key))
            #expect(try !send(manager, .keyUp, key: key))
            #expect(try send(manager, .keyDown, flags: flags, key: key))
            #expect(actions == [action, action])
        }
    }

    @Test(arguments: [ShortcutPreset.fn, .rightOption])
    func alternativePresetsRecognizeOnlyTheirOwnModifier(preset: ShortcutPreset) async throws {
        var actions: [HotkeyAction] = []
        let manager = HotkeyManager(preset: preset) { actions.append($0) }
        defer { manager.stop() }

        try send(manager, flags: controlOption)
        try await Task.sleep(for: .milliseconds(200))
        #expect(actions.isEmpty)
        try send(manager)
        // Aggregate Option alone must not mistake left Option for right Option.
        try send(manager, flags: .maskAlternate)
        try await Task.sleep(for: .milliseconds(200))
        #expect(actions.isEmpty)
        try send(manager)
        let flags: CGEventFlags = preset == .fn ? .maskSecondaryFn
            : CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)
        try send(manager, flags: flags)
        try await waitUntil { !actions.isEmpty }
        #expect(actions == [.beginDictation])
        try send(manager)
        #expect(actions == [.beginDictation, .endDictation])
        try send(manager, flags: commandHold)
        try await waitUntil { actions.count == 3 }
        #expect(actions.last == .beginCommand)
    }

    @Test func resetCancelsPendingHoldAndRequiresFullModifierRelease() async throws {
        var actions: [HotkeyAction] = []
        let manager = HotkeyManager { actions.append($0) }
        defer { manager.stop() }

        try send(manager, flags: controlOption)
        manager.resetCaptureState()
        manager.resetCaptureState()
        try send(manager, flags: .maskControl)
        try send(manager, flags: controlOption)
        try await Task.sleep(for: .milliseconds(200))
        #expect(actions.isEmpty)
        try send(manager)
        try send(manager, flags: controlOption)
        try await waitUntil { !actions.isEmpty }
        #expect(actions == [.beginDictation])
    }

    @Test(arguments: [false, true])
    func resetClearsActiveHoldWithoutEmittingEnd(command: Bool) async throws {
        var actions: [HotkeyAction] = []
        let manager = HotkeyManager { actions.append($0) }
        defer { manager.stop() }
        let flags = command ? commandHold : controlOption
        let begin: HotkeyAction = command ? .beginCommand : .beginDictation

        try send(manager, flags: flags)
        try await waitUntil { !actions.isEmpty }
        manager.isActive = true
        manager.resetCaptureState()
        #expect(manager.isActive)
        try send(manager, flags: flags)
        try await Task.sleep(for: .milliseconds(200))
        #expect(actions == [begin])
        try send(manager)
        #expect(actions == [begin])
        try send(manager, flags: flags)
        try await waitUntil { actions.count == 2 }
        #expect(actions == [begin, begin])
    }

    @Test func resetClearsToggleWhileJobsRemainActiveAndKeepsEscapeEnabled() async throws {
        var actions: [HotkeyAction] = []
        let manager = HotkeyManager { actions.append($0) }
        defer { manager.stop() }

        try send(manager, flags: controlOption)
        try send(manager, .keyDown, flags: controlOption, key: kVK_Space)
        manager.isActive = true // Background jobs remain active after UI Stop.
        manager.resetCaptureState()
        #expect(manager.isActive)
        #expect(try send(manager, .keyDown, flags: controlOption, key: kVK_Space, repeatKey: true))
        #expect(try send(manager, .keyUp, key: kVK_Space))
        try send(manager, flags: controlOption)
        try await Task.sleep(for: .milliseconds(200))
        #expect(actions == [.toggleDictation])
        try send(manager)
        try send(manager, flags: controlOption)
        try await waitUntil { actions.count == 2 }
        #expect(actions == [.toggleDictation, .beginDictation])
        manager.resetCaptureState()
        #expect(try send(manager, .keyDown, key: kVK_Escape))
        #expect(actions == [.toggleDictation, .beginDictation, .cancel])
        try send(manager)
        #expect(actions.count == 3)
    }

    @Test func stopCancelsPendingHold() async throws {
        var actions: [HotkeyAction] = []
        let manager = HotkeyManager { actions.append($0) }
        try send(manager, flags: controlOption)
        manager.stop()
        try await Task.sleep(for: .milliseconds(200))
        #expect(actions.isEmpty)
    }

    @Test func defaultDeliveryStillRequiresALiveTap() async throws {
        var actions: [HotkeyAction] = []
        let manager = HotkeyManager()
        manager.onAction = { actions.append($0) }
        defer { manager.stop() }

        #expect(try send(manager, .keyDown, flags: controlOption, key: kVK_Space))
        // Drain the main queue without ever installing a tap or launching the app.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(actions.isEmpty)
    }
}
