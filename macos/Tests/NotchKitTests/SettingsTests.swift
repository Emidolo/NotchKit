import AppKit
import Carbon.HIToolbox
import Testing
@testable import NotchKit

@Test func widgetOrderSurvivesAddedAndRemovedWidgets() {
    let known = ["music", "converter", "youtube", "wallpaper", "keepAwake"]
    #expect(WidgetStore.resolve(saved: [], known: known) == known)
    #expect(WidgetStore.resolve(saved: ["keepAwake", "music"], known: known) == ["keepAwake", "music", "converter", "youtube", "wallpaper"])
    #expect(WidgetStore.resolve(saved: ["gone", "music", "music"], known: known) == known)
}

@MainActor @Test func everyRegisteredWidgetHasAUniqueId() {
    let ids = WidgetStore.registry.map(\.id)
    #expect(Set(ids).count == ids.count)
    #expect(WidgetStore.shared.all.count == ids.count)
}

private func key(_ characters: String, code: Int, _ flags: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                     characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code))!
}

@Test func shortcutsNeedARealModifier() {
    let shortcut = Shortcut(event: key("n", code: kVK_ANSI_N, [.control, .option]))
    #expect(shortcut == .standard)
    #expect(Shortcut(event: key(" ", code: kVK_Space, [.command, .shift]))?.label == "⇧⌘Space")
    #expect(Shortcut(event: key("n", code: kVK_ANSI_N, [])) == nil)
    #expect(Shortcut(event: key("N", code: kVK_ANSI_N, [.shift])) == nil)
}

@MainActor @Test func hotKeyRegistersAndUnregisters() {
    #expect(HotKey.set(Shortcut(keyCode: UInt32(kVK_F19), modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey), label: "test")))
    #expect(HotKey.set(nil))
}
