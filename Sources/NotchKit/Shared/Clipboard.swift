import AppKit

/// Follows the clipboard for the widgets that react to copied text.
@MainActor
enum Clipboard {
    private static var timer: Timer?
    private static var lastChangeCount = 0

    /// Starts or stops the poll to match what the widgets want. Whatever is already on the clipboard is ignored.
    static func refresh() {
        let wanted = YouTubeModel.shared.detectClipboard || TyperModel.shared.armed
        guard wanted != (timer != nil) else { return }
        timer?.invalidate()
        timer = nil
        guard wanted else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        // The pasteboard has no change notification. One integer compare a second is the cheapest way to follow it.
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { check() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private static func check() {
        let count = NSPasteboard.general.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        YouTubeModel.shared.copied(text)
        TyperModel.shared.copied(text)
    }
}
