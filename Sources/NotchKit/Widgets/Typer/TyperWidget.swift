import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor extension Widget {
    static let typer = Widget(id: "typer", title: "Typer", icon: "keyboard", indicator: {
        let typer = TyperModel.shared
        guard typer.armed else { return nil }
        if let progress = typer.progress { return AnyView(ProgressRing(fraction: progress)) }
        if let countdown = typer.countdown {
            return AnyView(Text("\(countdown)").font(.system(size: 10, weight: .medium)).monospacedDigit()
                .accessibilityLabel("Typing starts in \(countdown) seconds"))
        }
        return AnyView(Image(systemName: "keyboard.fill").font(.system(size: 10, weight: .medium))
            .accessibilityLabel("Typer is on"))
    }) {
        AnyView(TyperView())
    }
}

/// Pure helpers: turning text into key presses.
enum Typer {
    enum Keystroke: Equatable {
        /// A real key, for the characters apps only understand as keys.
        case key(Int)
        /// Any other character, sent as text so the keyboard layout doesn't matter.
        case text(String)
    }

    static func keystrokes(_ text: String) -> [Keystroke] {
        text.map { character in
            switch character {
            case "\n", "\r", "\r\n": .key(kVK_Return)
            case "\t": .key(kVK_Tab)
            default: .text(String(character))
            }
        }
    }
}

/// Types copied text into whatever app has the cursor.
@MainActor @Observable
final class TyperModel {
    static let shared = TyperModel()
    /// Seconds between the copy and the first key, to get the cursor where the text should go.
    static let delay = 3

    /// Never saved: a relaunch must not come back typing.
    private(set) var armed = false
    /// Seconds left before typing starts; nil when nothing is waiting.
    private(set) var countdown: Int?
    /// How much of the text has been typed; nil when not typing.
    private(set) var progress: Double?
    private(set) var note: String?
    var charactersPerSecond = UserDefaults.standard.object(forKey: "typerSpeed") as? Double ?? 40 {
        didSet { UserDefaults.standard.set(charactersPerSecond, forKey: "typerSpeed") }
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var escapeMonitor: Any?

    func setArmed(_ on: Bool) {
        stop()
        note = nil
        // Posting keys to other apps needs the Accessibility permission; this shows the system prompt the first time.
        if on, !AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) {
            note = "Allow NotchKit in System Settings → Privacy & Security → Accessibility, then turn this on again."
            return
        }
        armed = on
        Clipboard.refresh()
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = !on ? nil : NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == UInt16(kVK_Escape) else { return }
            MainActor.assumeIsolated { TyperModel.shared.stop() }
        }
    }

    /// Stops the countdown or the typing; Typer stays on for the next copy.
    func stop() {
        task?.cancel()
        task = nil
        countdown = nil
        progress = nil
    }

    /// Text landed on the clipboard.
    func copied(_ text: String) {
        guard armed, WidgetStore.shared.isEnabled(Widget.typer.id), !text.isEmpty else { return }
        stop()
        let keystrokes = Typer.keystrokes(text)
        task = Task {
            for second in stride(from: TyperModel.delay, to: 0, by: -1) {
                countdown = second
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            countdown = nil
            for (index, keystroke) in keystrokes.enumerated() {
                progress = Double(index) / Double(keystrokes.count)
                TyperModel.post(keystroke)
                try? await Task.sleep(for: .seconds(1 / charactersPerSecond))
                if Task.isCancelled { return }
            }
            progress = nil
        }
    }

    private static func post(_ keystroke: Typer.Keystroke) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event: CGEvent?
            switch keystroke {
            case .key(let code):
                event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)
            case .text(let text):
                event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                let units = Array(text.utf16)
                event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
            // Without this a modifier still held from ⌘C would turn the text into shortcuts.
            event?.flags = []
            event?.post(tap: .cghidEventTap)
        }
    }
}

struct TyperView: View {
    @Bindable private var typer = TyperModel.shared

    var body: some View {
        HStack(spacing: 14) {
            Button { typer.setArmed(!typer.armed) } label: {
                Image(systemName: typer.armed ? "keyboard.fill" : "keyboard")
                    .font(.system(size: 24))
                    .frame(width: 60, height: 60)
                    .background(typer.armed ? Color.orange.opacity(0.85) : Color.white.opacity(0.1), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(typer.armed ? "Stop typing copied text" : "Type whatever is copied next")
            .accessibilityLabel(typer.armed ? "Turn Typer off" : "Turn Typer on")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(headline).font(.headline)
                    if typer.countdown != nil || typer.progress != nil {
                        Button("Stop") { typer.stop() }.help("Stop this text. Esc does the same.")
                    }
                }
                Text(typer.note ?? detail).font(.caption).foregroundStyle(typer.note == nil ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Slider(value: $typer.charactersPerSecond, in: 5...200) {
                    Text("\(Int(typer.charactersPerSecond)) characters a second").font(.caption).monospacedDigit()
                }
                .frame(maxWidth: 320)
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    private var headline: String {
        if let countdown = typer.countdown { return "Typing in \(countdown)…" }
        if let progress = typer.progress { return "Typing… \(Int(progress * 100))%" }
        return typer.armed ? "Waiting for a copy" : "Off"
    }

    private var detail: String {
        typer.armed
            ? "Copy text, click where it should go, and it is typed after \(TyperModel.delay) seconds. Esc stops it."
            : "Turn on, then copy text to have it typed wherever the cursor is."
    }
}
