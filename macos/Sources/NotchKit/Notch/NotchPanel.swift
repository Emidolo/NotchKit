import AppKit
import SwiftUI

/// Borderless overlay that sits above the menu bar and never activates the app.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        // Key only when a text field asks for it, so the frontmost app keeps focus.
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { true }
    // AppKit would otherwise push the window below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor @Observable
final class NotchController {
    static let shared = NotchController()

    private(set) var expanded = false
    /// Id of the widget on show. Falls back to the first visible one when empty or switched off.
    var selected = ""
    /// Height of the expanded panel, from Settings.
    var panelHeight = UserDefaults.standard.object(forKey: "panelHeight") as? Double ?? 160 {
        didSet {
            UserDefaults.standard.set(panelHeight, forKey: "panelHeight")
            place(expanded: expanded)
        }
    }
    var expandedSize: CGSize { CGSize(width: NotchGeometry.expandedWidth, height: panelHeight) }
    /// Notch in screen coordinates. Zero-sized (anchored under the menu bar) on Macs without one.
    private(set) var notch = CGRect.zero
    /// The collapsed notch is widened to make room for widget indicators.
    private(set) var ears = false
    /// Height of the tab strip that flanks the notch.
    var stripHeight: CGFloat { max(notch.height, 32) }

    @ObservationIgnored private let panel = NotchPanel()
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var displayID: CGDirectDisplayID = 0
    @ObservationIgnored private var safeTop: CGFloat = 0
    private let spring = Animation.spring(response: 0.38, dampingFraction: 0.8)

    private init() {
        let host = NSHostingView(rootView: NotchView(notch: self))
        host.sizingOptions = []
        panel.contentView = host
    }

    /// Re-reads the screen layout. Call at launch and whenever displays change.
    func refresh() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first else { return }
        displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        safeTop = screen.safeAreaInsets.top
        notch = NotchGeometry.notchRect(screen: screen.frame, safeTop: safeTop,
                                        leftAux: screen.auxiliaryTopLeftArea?.width,
                                        rightAux: screen.auxiliaryTopRightArea?.width)
            ?? CGRect(x: screen.frame.midX, y: screen.visibleFrame.maxY, width: 0, height: 0)
        place(expanded: expanded)
    }

    func toggle() { expanded ? collapse() : expand() }

    func expand() {
        pending?.cancel()
        guard !expanded else { return }
        // Grow the window first so the animation has room; shrink it only once the collapse has finished.
        // The window never covers more than the visible shape, so clicks beside it reach other apps.
        place(expanded: true)
        withAnimation(spring) { expanded = true }
    }

    /// Opens without a hover (a link was copied) and closes again if the cursor never comes over.
    func peek() {
        expand()
        pending = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            if !panel.frame.contains(NSEvent.mouseLocation) { collapse() }
        }
    }

    func setEars(_ on: Bool) {
        ears = on
        if !expanded { place(expanded: false) }
    }

    func collapse() {
        guard expanded else { return }
        withAnimation(spring) { expanded = false } completion: {
            if !self.expanded { self.place(expanded: false) }
        }
    }

    /// Hover (or a drag) entered or left the notch. Opens after the hover delay, closes shortly after leaving.
    func hover(_ inside: Bool) {
        pending?.cancel()
        let delay = inside ? UserDefaults.standard.double(forKey: "hoverDelay") : 0.2
        pending = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            if inside {
                expand()
            } else if RunLoop.main.currentMode == .eventTracking {
                // A menu opened from the panel (or a slider drag) is in progress; look again once it ends.
                hover(false)
            } else if !panel.frame.insetBy(dx: -1, dy: -1).contains(NSEvent.mouseLocation) {
                // Exit events also fire when the window resizes under a still cursor; only close if it really left.
                collapse()
            }
        }
    }

    /// Files dropped anywhere on the notch go to the Converter.
    func drop(_ providers: [NSItemProvider]) {
        selected = Widget.converter.id
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in ConverterModel.shared.add([url]) }
            }
        }
    }

    /// Shows or hides the panel. Call when the active Space or the fullscreen setting changes.
    func updateVisibility() { place(expanded: expanded) }

    private func place(expanded: Bool) {
        let hidden = (!expanded && notch.isEmpty)
            || (UserDefaults.standard.bool(forKey: "hideInFullscreen") && inFullscreen)
        guard !hidden else { return panel.orderOut(nil) }
        let collapsed = notch.insetBy(dx: ears ? -NotchGeometry.earWidth : 0, dy: 0)
        panel.setFrame(expanded ? NotchGeometry.expandedRect(around: notch, size: expandedSize) : collapsed, display: true)
        panel.orderFrontRegardless()
    }

    private var inFullscreen: Bool {
        let display = CGDisplayBounds(displayID)
        let me = ProcessInfo.processInfo.processIdentifier
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.contains { w in
            guard w[kCGWindowLayer as String] as? Int == 0,
                  w[kCGWindowOwnerPID as String] as? pid_t != me,
                  let bounds = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return NotchGeometry.isFullscreen(window: rect, display: display, safeTop: safeTop)
        }
    }
}
