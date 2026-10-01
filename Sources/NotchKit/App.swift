import AppKit

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["hoverDelay": 0.15])

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "NotchKit")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // An accessory app has no menu bar, but ⌘X/⌘C/⌘V/⌘A/⌘W in its text fields and windows are routed through this menu.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        NSApp.mainMenu = NSMenu()
        NSApp.mainMenu?.addItem(editItem)

        NotchController.shared.refresh()
        YouTubeModel.shared.startWatchingClipboard()
        KeepAwake.shared.start()
        Preferences.shared.applyShortcut()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        // For checking layouts without a mouse:
        //   open NotchKit.app --args --open [widget id]     starts expanded
        //   open NotchKit.app --args --settings [tab]       opens Settings
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--open") {
            if let id = arguments.dropFirst(flag + 1).first, !id.hasPrefix("--") { NotchController.shared.selected = id }
            NotchController.shared.expand()
        }
        if let flag = arguments.firstIndex(of: "--settings") {
            SettingsWindow.show(tab: arguments.dropFirst(flag + 1).first.flatMap { $0.hasPrefix("--") ? nil : $0 })
        }
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

    // MARK: Status menu (the way in on Macs without a notch)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let open = item(NotchController.shared.expanded ? "Close Notch" : "Open Notch", #selector(toggleNotch))
        if Preferences.shared.shortcutEnabled, !Preferences.shared.shortcutRefused { open.title += "   " + Preferences.shared.shortcut.label }
        menu.addItem(open)
        menu.addItem(item("Settings…", #selector(showSettings)))
        menu.addItem(.separator())
        menu.addItem(item("Quit NotchKit", #selector(NSApplication.terminate(_:)), target: NSApp))
    }

    private func item(_ title: String, _ action: Selector, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target ?? self
        return item
    }

    @objc private func toggleNotch() {
        NotchController.shared.toggle()
    }

    @objc private func showSettings() {
        SettingsWindow.show()
    }
}
