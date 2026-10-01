import AppKit
import Carbon.HIToolbox

/// A key combination for the system-wide "open the notch" shortcut.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier mask (cmdKey, optionKey, controlKey, shiftKey).
    var modifiers: UInt32
    /// For display, e.g. "⌃⌥N".
    var label: String

    static let standard = Shortcut(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥N")

    init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    /// From a key press. Needs ⌘, ⌥ or ⌃, so a plain letter can never become a global shortcut.
    init?(event: NSEvent) {
        let flags = event.modifierFlags
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        let names: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
                                    kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓"]
        guard let key = names[Int(event.keyCode)] ?? event.charactersIgnoringModifiers?.uppercased(), !key.isEmpty else { return nil }
        var mask = 0, label = ""
        for (flag, carbon, symbol) in [(NSEvent.ModifierFlags.control, controlKey, "⌃"), (.option, optionKey, "⌥"),
                                       (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")] where flags.contains(flag) {
            mask |= carbon
            label += symbol
        }
        self.init(keyCode: UInt32(event.keyCode), modifiers: UInt32(mask), label: label + key)
    }
}

/// The global shortcut, through Carbon's hot-key API: no Accessibility permission and no event tap,
/// so nothing runs until the keys are pressed.
@MainActor
enum HotKey {
    private static var reference: EventHotKeyRef?
    private static var installed = false

    /// Makes `shortcut` toggle the notch; nil removes it. False if the system refused the combination.
    @discardableResult
    static func set(_ shortcut: Shortcut?) -> Bool {
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                Task { @MainActor in NotchController.shared.toggle() }
                return noErr
            }, 1, &spec, nil, nil)
            installed = true
        }
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        guard let shortcut else { return true }
        let id = EventHotKeyID(signature: OSType(0x4E4B_4559), id: 1)   // 'NKEY'
        return RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &reference) == noErr
    }
}
