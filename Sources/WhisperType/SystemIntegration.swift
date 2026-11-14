import AppKit
@preconcurrency import CoreFoundation
@preconcurrency import ApplicationServices
import Carbon
import Security
import ServiceManagement
import WhisperCore

enum HotkeyAction: Equatable {
    case beginDictation, endDictation, toggleDictation
    case beginCommand, endCommand
    case cancel, cancelForCommandUpgrade, pasteLast, copyLast, transformSelection
}

@MainActor
final class HotkeyManager {
    var onAction: ((HotkeyAction) -> Void)?
    var isActive = false {
        didSet {
            if !isActive {
                toggleEngaged = false
                if activeHold != nil {
                    activeHold = nil
                    blockHoldsUntilRelease = true
                }
            }
        }
    }

    private enum Hold: Equatable { case dictation, command }
    private var preset: ShortcutPreset
    private let actionDelivery: ((HotkeyAction) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var pendingHold: Task<Void, Never>?
    private var desiredHold: Hold?
    private var activeHold: Hold?
    private var toggleEngaged = false
    private var blockHoldsUntilRelease = false
    private var swallowedKeys: Set<Int64> = []
    private var generation = 0

    init(preset: ShortcutPreset = .controlOption, actionDelivery: ((HotkeyAction) -> Void)? = nil) {
        self.preset = preset
        self.actionDelivery = actionDelivery
    }

    @discardableResult
    func start(preset: ShortcutPreset) -> Bool {
        stop()
        self.preset = preset
        // An active tap needs Accessibility to consume shortcuts. Input Monitoring
        // allows global observation. Starting never presents a permission prompt.
        guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else { return false }
        let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                // The source is installed exclusively on the main run loop.
                let swallowed = MainActor.assumeIsolated {
                    let manager = Unmanaged<HotkeyManager>.fromOpaque(info).takeUnretainedValue()
                    return manager.handle(type, event: event)
                }
                return swallowed ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        self.tap = tap
        self.source = source
        blockHoldsUntilRelease = !CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]).isEmpty
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            stop()
            return false
        }
        return true
    }

    // Capture can stop while background jobs keep isActive (and Escape) enabled.
    func resetCaptureState() {
        generation += 1
        pendingHold?.cancel()
        pendingHold = nil
        desiredHold = nil
        activeHold = nil
        toggleEngaged = false
        blockHoldsUntilRelease = true
    }

    func stop() {
        resetCaptureState()
        swallowedKeys.removeAll()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    deinit {
        pendingHold?.cancel()
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    private func emit(_ action: HotkeyAction) {
        if let actionDelivery {
            actionDelivery(action)
            return
        }
        let generation = generation
        // Client work (including AX calls) must not run inside the event tap.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation, self.tap != nil else { return }
            self.onAction?(action)
        }
    }

    func handle(_ type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            resetCaptureState()
            swallowedKeys.removeAll()
            if isActive { emit(.cancel) }
            if let tap, CFMachPortIsValid(tap), AXIsProcessTrusted(), CGPreflightListenEventAccess() {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return false
        }

        let flags = event.flags
        let modifiers = flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift])
        if type == .flagsChanged {
            let holdModifiers = flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn])
            if holdModifiers.isEmpty { blockHoldsUntilRelease = false }
            var hold: Hold?
            if !blockHoldsUntilRelease && !toggleEngaged {
                if modifiers == [.maskControl, .maskAlternate, .maskCommand] {
                    hold = .command
                } else {
                    switch preset {
                    case .controlOption:
                        if modifiers == [.maskControl, .maskAlternate] { hold = .dictation }
                    case .rightOption:
                        // NX_DEVICERALTKEYMASK distinguishes right Option even while
                        // left Option is also held; aggregate Option flags cannot.
                        if modifiers == [.maskAlternate], flags.rawValue & 0x40 != 0 { hold = .dictation }
                    case .fn:
                        if modifiers.isEmpty, flags.contains(.maskSecondaryFn) { hold = .dictation }
                    }
                }
            }
            updateHold(hold)
            if holdModifiers.isEmpty { blockHoldsUntilRelease = false }
            return false // Modifier-only holds never consume modifier events.
        }

        // Read only shortcut keycodes and repeat state, never Unicode/key text.
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp {
            let swallowed = swallowedKeys.remove(key) != nil
            return swallowed && (key != Int64(kVK_Escape) || isActive)
        }
        guard type == .keyDown else { return false }
        if swallowedKeys.contains(key) {
            return key != Int64(kVK_Escape) || isActive
        }

        var action: HotkeyAction?
        if key == Int64(kVK_Escape), isActive {
            action = .cancel
        } else if modifiers == [.maskControl, .maskAlternate] {
            if key == Int64(kVK_Space) { action = .toggleDictation }
            if key == Int64(kVK_ANSI_P) { action = .transformSelection }
        } else if modifiers == [.maskControl, .maskCommand] {
            if key == Int64(kVK_ANSI_C) { action = .copyLast }
            if key == Int64(kVK_ANSI_V) { action = .pasteLast }
        }
        guard let action else {
            if desiredHold != nil {
                updateHold(nil)
                blockHoldsUntilRelease = true
            }
            return false
        }
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return true }
        swallowedKeys.insert(key)
        pendingHold?.cancel()
        pendingHold = nil
        desiredHold = nil
        blockHoldsUntilRelease = true
        switch action {
        case .toggleDictation:
            // Latch an existing hold instead of ending it on modifier release.
            let latchExistingHold = activeHold == .dictation
            toggleEngaged = latchExistingHold || !toggleEngaged
            activeHold = nil
            if latchExistingHold { return true }
        case .cancel:
            activeHold = nil
            toggleEngaged = false
        default:
            if let activeHold { emit(activeHold == .command ? .endCommand : .endDictation) }
            activeHold = nil
        }
        emit(action)
        return true
    }

    private func updateHold(_ hold: Hold?) {
        guard hold != desiredHold else { return }
        let previousHold = desiredHold
        desiredHold = hold
        pendingHold?.cancel()
        pendingHold = nil
        if let activeHold {
            // A late Command modifier upgrades a hold without submitting a stray
            // dictation first. Clients receive cancel before the new beginCommand.
            emit(hold == .command ? .cancelForCommandUpgrade : (activeHold == .command ? .endCommand : .endDictation))
            self.activeHold = nil
            if hold != .command {
                desiredHold = nil
                blockHoldsUntilRelease = true
                return
            }
        } else if previousHold == .command, hold == .dictation {
            // Releasing Command first must not start a new dictation hold.
            desiredHold = nil
            blockHoldsUntilRelease = true
            return
        }
        guard let hold else { return }
        let generation = generation
        pendingHold = Task { @MainActor [weak self] in
            // Let Space/P/Command disambiguate the shared modifier prefix.
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard let self, self.generation == generation, self.desiredHold == hold,
                  !self.blockHoldsUntilRelease, !self.toggleEngaged else { return }
            self.pendingHold = nil
            self.activeHold = hold
            self.emit(hold == .command ? .beginCommand : .beginDictation)
        }
    }
}

@MainActor
struct InsertionTarget {
    let context: TextContext
    let pid: pid_t
    let isSecure: Bool
    // Full text stays local for compare-before-write, even when context is off.
    fileprivate let element: AXUIElement?
    fileprivate let selection: NSRange?
    fileprivate let value: String?
}

@MainActor
final class TextInsertionService {
    var accessibilityGranted: Bool { AXIsProcessTrusted() }
    private var insertionInProgress = false

    func requestAccessibility() { SystemPermissions.requestAccessibility() }

    func captureTarget(includeContext: Bool) -> InsertionTarget {
        let app = NSWorkspace.shared.frontmostApplication
        let pid = app?.processIdentifier ?? -1
        var context = TextContext(appName: app?.localizedName ?? "", bundleID: app?.bundleIdentifier ?? "")
        var target = InsertionTarget(context: context, pid: pid, isSecure: false,
                                     element: nil, selection: nil, value: nil)
        if IsSecureEventInputEnabled() {
            return InsertionTarget(context: context, pid: pid, isSecure: true,
                                   element: nil, selection: nil, value: nil)
        }
        guard accessibilityGranted, let element = focusedElement(pid: pid) else { return target }
        if IsSecureEventInputEnabled() || isSecure(element) {
            return InsertionTarget(context: context, pid: pid, isSecure: true,
                                   element: nil, selection: nil, value: nil)
        }
        context.selectedText = attribute(kAXSelectedTextAttribute, of: element) as? String ?? ""
        guard let snapshot = snapshot(element) else {
            // Read-only/custom controls may expose a selection but not a complete
            // editable snapshot. Commands can use it, but insertion stays disabled.
            guard !IsSecureEventInputEnabled(), let focused = focusedElement(pid: pid),
                  CFEqual(element, focused), !isSecure(focused) else { return target }
            return InsertionTarget(context: context, pid: pid, isSecure: false,
                                   element: nil, selection: nil, value: nil)
        }
        let value = snapshot.value as NSString
        context.selectedText = value.substring(with: snapshot.selection)
        if includeContext, let range = Range(snapshot.selection, in: snapshot.value) {
            context.surroundingText = String(snapshot.value[..<range.lowerBound].suffix(2000))
                + String(context.selectedText.prefix(2000))
                + String(snapshot.value[range.upperBound...].prefix(2000))
        }
        target = InsertionTarget(context: context, pid: pid, isSecure: false,
                                 element: element, selection: snapshot.selection, value: snapshot.value)
        guard matches(target) else {
            context.selectedText = ""
            context.surroundingText = ""
            return InsertionTarget(context: context, pid: pid, isSecure: false,
                                   element: nil, selection: nil, value: nil)
        }
        return target
    }

    func selectedText() -> String { captureTarget(includeContext: false).context.selectedText }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func pasteIntoCurrentApp(_ text: String, restoreClipboard: Bool) async -> Bool {
        let target = captureTarget(includeContext: false)
        return await insert(text, into: target, restoreClipboard: restoreClipboard)
    }

    func insert(_ text: String, into target: InsertionTarget, restoreClipboard: Bool) async -> Bool {
        guard !insertionInProgress, !Task.isCancelled, matches(target),
              let element = target.element, let value = target.value, let selection = target.selection else { return false }
        insertionInProgress = true
        defer { insertionInProgress = false }
        let expected = (value as NSString).replacingCharacters(in: selection, with: text)
        var settable = DarwinBoolean(false)
        let availability = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        if availability == .success, settable.boolValue {
            guard !Task.isCancelled, matches(target) else { return false }
            let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
            // Once a setter was attempted, never retry with paste: a timed-out or
            // asynchronous setter may still have applied, causing duplicate text.
            guard result == .success else { return false }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
            return !Task.isCancelled && matches(target, expectedValue: expected)
        }
        guard availability == .success || availability == .attributeUnsupported || availability == .notImplemented else { return false }
        var valueSettable = DarwinBoolean(false)
        let valueAvailability = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable)
        guard (valueAvailability == .success && valueSettable.boolValue)
                || (attribute("AXEditable", of: element) as? Bool) == true else { return false }

        // Wait briefly for the user's shortcut modifiers to be released rather
        // than combining physical Control/Option with the synthetic Command-V.
        for _ in 0..<25 {
            if CGEventSource.flagsState(.combinedSessionState)
                .intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift]).isEmpty { break }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return false }
        }
        guard !Task.isCancelled, matches(target),
              CGEventSource.flagsState(.combinedSessionState)
                .intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift]).isEmpty,
              let eventSource = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand

        let pasteboard = NSPasteboard.general
        let originalCount = pasteboard.changeCount
        var savedItems: [NSPasteboardItem] = []
        if restoreClipboard {
            let items = pasteboard.pasteboardItems ?? []
            guard !items.isEmpty || (pasteboard.types ?? []).isEmpty else { return false }
            for item in items {
                guard !item.types.isEmpty else { return false }
                let saved = NSPasteboardItem()
                for type in item.types {
                    // Refuse to overwrite a promised type that cannot be saved.
                    guard let data = item.data(forType: type), saved.setData(data, forType: type) else { return false }
                }
                savedItems.append(saved)
            }
        }
        let replacement = NSPasteboardItem()
        guard replacement.setString(text, forType: .string), !Task.isCancelled,
              matches(target), pasteboard.changeCount == originalCount else { return false }
        var ownedCount = pasteboard.clearContents()
        defer {
            // A user/app clipboard update always wins, including during await.
            if restoreClipboard, pasteboard.changeCount == ownedCount {
                pasteboard.clearContents()
                if !savedItems.isEmpty { pasteboard.writeObjects(savedItems) }
            }
        }
        guard pasteboard.writeObjects([replacement]) else { return false }
        ownedCount = pasteboard.changeCount
        guard !Task.isCancelled, matches(target), pasteboard.changeCount == ownedCount else { return false }
        // Address the original process, never activate it or use a global paste.
        // There is no await between the last focus check and the paired events.
        down.postToPid(target.pid)
        up.postToPid(target.pid)
        // Cancellation must not restore the clipboard before the app reads it.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { continuation.resume() }
        }
        return !Task.isCancelled && matches(target, expectedValue: expected)
    }

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func focusedElement(pid: pid_t) -> AXUIElement? {
        guard pid > 0, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        let app = AXUIElementCreateApplication(pid)
        guard AXUIElementSetMessagingTimeout(app, 0.15) == .success,
              let value = attribute(kAXFocusedUIElementAttribute, of: app),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        var elementPID: pid_t = -1
        guard AXUIElementSetMessagingTimeout(element, 0.15) == .success,
              AXUIElementGetPid(element, &elementPID) == .success, elementPID == pid else { return nil }
        return element
    }

    private func isSecure(_ element: AXUIElement) -> Bool {
        var current = element
        var visited: [AXUIElement] = []
        // Secure subroles can be on an enclosing element in web/custom controls.
        for _ in 0..<16 {
            guard !visited.contains(where: { CFEqual($0, current) }),
                  AXUIElementSetMessagingTimeout(current, 0.15) == .success else { return true }
            visited.append(current)
            for name in [kAXRoleAttribute, kAXSubroleAttribute, "AXProtectedContent"] {
                var value: CFTypeRef?
                let result = AXUIElementCopyAttributeValue(current, name as CFString, &value)
                if result == .attributeUnsupported || result == .noValue { continue }
                guard result == .success else { return true }
                if name == "AXProtectedContent", (value as? Bool) == true { return true }
                if let description = value as? String {
                    let lower = description.lowercased()
                    if lower.contains("secure") || lower.contains("password") { return true }
                }
            }
            var parent: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent)
            if result == .noValue || result == .attributeUnsupported { return false }
            guard result == .success else { return true }
            guard let parent else { return false }
            guard CFGetTypeID(parent) == AXUIElementGetTypeID() else { return true }
            current = parent as! AXUIElement
        }
        return true
    }

    private func snapshot(_ element: AXUIElement) -> (value: String, selection: NSRange)? {
        guard let role = attribute(kAXRoleAttribute, of: element) as? String,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
              (attribute(kAXEnabledAttribute, of: element) as? Bool) != false,
              let value = attribute(kAXValueAttribute, of: element) as? String,
              let selectionValue = attribute(kAXSelectedTextRangeAttribute, of: element),
              CFGetTypeID(selectionValue) == AXValueGetTypeID() else { return nil }
        let axRange = selectionValue as! AXValue
        var range = CFRange()
        guard AXValueGetType(axRange) == .cfRange, AXValueGetValue(axRange, .cfRange, &range),
              range.location >= 0, range.length >= 0 else { return nil }
        let length = (value as NSString).length
        guard range.location <= length, range.length <= length - range.location else { return nil }
        let selection = NSRange(location: range.location, length: range.length)
        if let selected = attribute(kAXSelectedTextAttribute, of: element) as? String,
           !selected.utf16.elementsEqual((value as NSString).substring(with: selection).utf16) { return nil }
        return (value, selection)
    }

    private func matches(_ target: InsertionTarget, expectedValue: String? = nil) -> Bool {
        guard accessibilityGranted, !target.isSecure, !IsSecureEventInputEnabled(),
              let element = target.element, let value = target.value, let selection = target.selection,
              let focused = focusedElement(pid: target.pid), CFEqual(element, focused),
              !isSecure(focused), let current = snapshot(focused) else { return false }
        if let expectedValue {
            guard current.value.utf16.elementsEqual(expectedValue.utf16) else { return false }
        } else {
            // AX ranges use UTF-16 offsets; canonical String equality is too weak.
            guard current.value.utf16.elementsEqual(value.utf16), current.selection == selection else { return false }
        }
        guard let focused = focusedElement(pid: target.pid) else { return false }
        return CFEqual(element, focused)
    }
}

enum KeychainStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.whispertype.mac",
         kSecAttrAccount as String: "api-key",
         kSecAttrSynchronizable as String: false]
    }

    static func loadAPIKey() throws -> String? {
        var query = query
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecDecode))
        }
        return value
    }

    static func saveAPIKey(_ value: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            try check(SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    static func deleteAPIKey() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private static func check(_ status: OSStatus) throws {
        guard status != errSecSuccess else { return }
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain operation failed (\(status))."
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                      userInfo: [NSLocalizedDescriptionKey: message])
    }
}

enum LoginItemService {
    static func setEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }
}

@MainActor
enum SystemPermissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }
    static var inputMonitoringGranted: Bool { CGPreflightListenEventAccess() }
    static let accessibilityExplanation = "Allow WhisperType in System Settings > Privacy & Security > Accessibility to use global shortcuts and insert text into the focused app."
    static let inputMonitoringExplanation = "Allow WhisperType in System Settings > Privacy & Security > Input Monitoring to detect dictation shortcuts. WhisperType checks modifier and shortcut keycodes only; it does not capture typed text. You may need to quit and reopen the app after granting access."

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    static func requestInputMonitoring() -> Bool { CGRequestListenEventAccess() }

    @discardableResult
    static func openAccessibilitySettings() -> Bool {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @discardableResult
    static func openInputMonitoringSettings() -> Bool {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
}
