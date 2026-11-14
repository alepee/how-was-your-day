import AppKit
import Carbon.HIToolbox

/// A key combination stored in preferences. Modifiers use the Carbon mask expected by
/// `RegisterEventHotKey`; `display` is captured when the shortcut is recorded.
struct RecordingShortcut: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String
    static let standard = RecordingShortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey | cmdKey), display: "⌃⌥⌘R")

    /// Builds a shortcut from a key press. A global shortcut needs Command, Control or Option,
    /// otherwise it would swallow ordinary typing in every application.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        var carbon = 0
        if flags.contains(.command) { carbon |= cmdKey }
        if flags.contains(.control) { carbon |= controlKey }
        if flags.contains(.option) { carbon |= optionKey }
        if flags.contains(.shift) { carbon |= shiftKey }
        keyCode = UInt32(event.keyCode); modifiers = UInt32(carbon)
        let symbols = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
        display = symbols + Self.keyName(event)
    }
    init(keyCode: UInt32, modifiers: UInt32, display: String) { self.keyCode = keyCode; self.modifiers = modifiers; self.display = display }
    private static func keyName(_ event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: String(localized: "Espace")
        case kVK_Return: "↩"
        case kVK_Tab: "⇥"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        case kVK_Home: "↖"
        case kVK_End: "↘"
        case kVK_PageUp: "⇞"
        case kVK_PageDown: "⇟"
        case kVK_Escape: "⎋"
        default:
            if let special = [kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
                              kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"][Int(event.keyCode)] { special }
            else { (event.charactersIgnoringModifiers ?? "?").uppercased() }
        }
    }
}

/// One system-wide hot key through Carbon. It needs no Accessibility permission and is delivered
/// even when another application is active.
@MainActor final class GlobalHotKey {
    static let shared = GlobalHotKey()
    private var reference: EventHotKeyRef?
    private var handlerInstalled = false
    fileprivate var action: (() -> Void)?
    private static let signature: OSType = 0x4857_5944 // 'HWYD'

    /// Replaces the registered shortcut. Returns false when another application already owns it.
    @discardableResult func register(_ shortcut: RecordingShortcut?, action: @escaping () -> Void) -> Bool {
        unregister()
        self.action = action
        guard let shortcut else { return true }
        installHandler()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: Self.signature, id: 1),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        reference = ref
        return true
    }
    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
    }
    private func installHandler() {
        guard !handlerInstalled else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var identifier = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard identifier.signature == GlobalHotKey.signature else { return OSStatus(eventNotHandledErr) }
            Task { @MainActor in GlobalHotKey.shared.action?() }
            return noErr
        }, 1, &type, nil, nil)
        handlerInstalled = true
    }
}
