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

        // An accessory app has no menu bar, but ⌘X/⌘C/⌘V/⌘A in the notch's text fields are routed through this menu.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        NSApp.mainMenu = NSMenu()
        NSApp.mainMenu?.addItem(editItem)

        NotchController.shared.refresh()
        YouTubeModel.shared.startWatchingClipboard()
        KeepAwake.shared.start()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        // `open NotchKit.app --args --open [widget id]` starts expanded, for checking a layout without a mouse.
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--open") {
            if let id = arguments.dropFirst(flag + 1).first, widgets.contains(where: { $0.id == id }) { NotchController.shared.selected = id }
            NotchController.shared.expand()
        }
        if arguments.contains("--settings") { KeepAwakeSettings.show() }
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        NotchController.shared.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        KeepAwake.shared.closedLid.revertNow()
    }

    /// `notchkit://` URLs come from the Claude Code hooks. Files opened with the app
    /// (`open -a NotchKit photo.png`, or dropped on its icon) go to the Converter.
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.compactMap(ClaudeEvent.init(url:)).forEach(KeepAwake.shared.claudeEvent)
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        ConverterModel.shared.add(files)
        NotchController.shared.selected = Widget.converter.id
        NotchController.shared.expand()
    }

    @objc private func spaceChanged() {
        NotchController.shared.updateVisibility()
    }

    // MARK: Status menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item(NotchController.shared.expanded ? "Close Notch" : "Open Notch", #selector(toggleNotch)))
        menu.addItem(.separator())
        menu.addItem(item("Keep Awake Rules…", #selector(showKeepAwakeRules)))
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

    @objc private func showKeepAwakeRules() {
        KeepAwakeSettings.show()
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
