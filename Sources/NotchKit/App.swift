import AppKit
import ServiceManagement

@main @MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var statusItem: NSStatusItem!
    private let defaults = UserDefaults.standard

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["hoverDelay": 0.15])

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "NotchKit")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        NotchController.shared.refresh()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        // `open NotchKit.app --args --open` starts expanded, for checking the layout without a mouse.
        if CommandLine.arguments.contains("--open") { NotchController.shared.expand() }
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        NotchController.shared.refresh()
    }

    @objc private func spaceChanged() {
        NotchController.shared.updateVisibility()
    }

    // MARK: Status menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item(NotchController.shared.expanded ? "Close Notch" : "Open Notch", #selector(toggleNotch)))
        menu.addItem(.separator())
        menu.addItem(item("Hide in Fullscreen", #selector(toggleHideInFullscreen), on: defaults.bool(forKey: "hideInFullscreen")))
        menu.addItem(item("Launch at Login", #selector(toggleLaunchAtLogin), on: SMAppService.mainApp.status == .enabled))
        menu.addItem(.separator())
        menu.addItem(item("Quit NotchKit", #selector(NSApplication.terminate(_:)), target: NSApp))
    }

    private func item(_ title: String, _ action: Selector, on: Bool = false, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target ?? self
        item.state = on ? .on : .off
        return item
    }

    @objc private func toggleNotch() {
        NotchController.shared.toggle()
    }

    @objc private func toggleHideInFullscreen() {
        defaults.set(!defaults.bool(forKey: "hideInFullscreen"), forKey: "hideInFullscreen")
        NotchController.shared.updateVisibility()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
