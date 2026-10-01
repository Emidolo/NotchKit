import AppKit
import ServiceManagement
import SwiftUI

/// App-wide preferences that aren't owned by a widget.
@MainActor @Observable
final class Preferences {
    static let shared = Preferences()
    private static let defaults = UserDefaults.standard

    /// The Settings tab on show.
    var tab = "general"
    /// Seconds the cursor must rest on the notch before it opens.
    var hoverDelay = defaults.double(forKey: "hoverDelay") {
        didSet { Preferences.defaults.set(hoverDelay, forKey: "hoverDelay") }
    }
    var hideInFullscreen = defaults.bool(forKey: "hideInFullscreen") {
        didSet {
            Preferences.defaults.set(hideInFullscreen, forKey: "hideInFullscreen")
            NotchController.shared.updateVisibility()
        }
    }
    var shortcutEnabled = defaults.object(forKey: "shortcutEnabled") as? Bool ?? true {
        didSet {
            Preferences.defaults.set(shortcutEnabled, forKey: "shortcutEnabled")
            applyShortcut()
        }
    }
    var shortcut = defaults.data(forKey: "shortcut").flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .standard {
        didSet {
            Preferences.defaults.set(try? JSONEncoder().encode(shortcut), forKey: "shortcut")
            applyShortcut()
        }
    }
    /// The system refused the shortcut, usually because another app has it.
    private(set) var shortcutRefused = false
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var launchAtLoginError: String?

    func applyShortcut() {
        shortcutRefused = !HotKey.set(shortcutEnabled ? shortcut : nil)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// Asks for a folder. The app has to come forward for the dialog to take keys.
@MainActor
func chooseFolder(startingAt directory: URL? = nil) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.directoryURL = directory
    NSApp.activate(ignoringOtherApps: true)
    return panel.runModal() == .OK ? panel.url : nil
}

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show(tab: String? = nil) {
        if let tab { Preferences.shared.tab = tab }
        if window == nil {
            let created = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            created.title = "NotchKit Settings"
            created.styleMask = [.titled, .closable]
            created.isReleasedWhenClosed = false
            // Opens on the Space you're in, including over a fullscreen app, instead of back on the desktop.
            created.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            created.center()
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @Bindable private var preferences = Preferences.shared

    var body: some View {
        TabView(selection: $preferences.tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            WidgetSettings().tabItem { Label("Widgets", systemImage: "square.grid.2x2") }.tag("widgets")
            KeepAwakeSettingsView().tabItem { Label("Keep Awake", systemImage: "cup.and.saucer") }.tag("keepAwake")
        }
        .frame(width: 540, height: 620)
    }
}

private struct GeneralSettings: View {
    @Bindable private var preferences = Preferences.shared
    @Bindable private var notch = NotchController.shared
    @Bindable private var converter = ConverterModel.shared
    @Bindable private var youTube = YouTubeModel.shared

    var body: some View {
        Form {
            Section("Notch") {
                Slider(value: $preferences.hoverDelay, in: 0...1, step: 0.05) {
                    Text("Open after hovering for \(preferences.hoverDelay, format: .number.precision(.fractionLength(2))) s")
                }
                Picker("Panel height", selection: $notch.panelHeight) {
                    Text("Compact").tag(160.0)
                    Text("Regular").tag(220.0)
                    Text("Tall").tag(300.0)
                }
                Toggle("Hide over fullscreen apps", isOn: $preferences.hideInFullscreen)
                Toggle("Keyboard shortcut to open the notch", isOn: $preferences.shortcutEnabled)
                if preferences.shortcutEnabled {
                    LabeledContent("Shortcut") { ShortcutRecorder() }
                    if preferences.shortcutRefused {
                        Text("macOS refused this shortcut. Another app is probably using it; record a different one.")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(get: { preferences.launchAtLogin }, set: { preferences.setLaunchAtLogin($0) }))
                Text(preferences.launchAtLoginError ?? "Registers the copy of NotchKit that is running now, so keep it in /Applications.")
                    .font(.caption).foregroundStyle(preferences.launchAtLoginError == nil ? Color.secondary : Color.red)
            }

            Section("Folders") {
                LabeledContent("Converted files") {
                    Text(converter.outputDirectory?.path ?? "Next to the original").lineLimit(1).truncationMode(.head)
                    Button("Choose…") { if let url = chooseFolder(startingAt: converter.outputDirectory) { converter.outputDirectory = url } }
                    if converter.outputDirectory != nil { Button("Reset") { converter.outputDirectory = nil } }
                }
                LabeledContent("Downloads") {
                    Text(youTube.directory.path).lineLimit(1).truncationMode(.head)
                    Button("Choose…") { if let url = chooseFolder(startingAt: youTube.directory) { youTube.directory = url } }
                }
            }

            Section("Clipboard") {
                Toggle("Offer a download when a YouTube link is copied", isOn: $youTube.detectClipboard)
            }
        }
        .formStyle(.grouped)
    }
}

/// Click, then press the new combination. Esc cancels.
private struct ShortcutRecorder: View {
    private let preferences = Preferences.shared
    @State private var monitor: Any?

    var body: some View {
        Button(monitor == nil ? preferences.shortcut.label : "Press a shortcut…") {
            monitor == nil ? start() : stop()
        }
        .help("Click, then press the keys. Needs ⌘, ⌥ or ⌃. Esc cancels.")
        .onDisappear(perform: stop)
    }

    private func start() {
        // Only sees keys while this window has focus, and swallows them so they don't type anywhere.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                if let shortcut = Shortcut(event: event) { preferences.shortcut = shortcut }
                if event.keyCode == 53 || Shortcut(event: event) != nil { stop() }
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private struct WidgetSettings: View {
    private let store = WidgetStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            List {
                ForEach(store.all) { widget in
                    HStack {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).accessibilityHidden(true)
                        Image(systemName: widget.icon).frame(width: 22)
                        Text(widget.title)
                        Spacer()
                        Toggle(widget.title, isOn: Binding(get: { store.isEnabled(widget.id) }, set: { store.setEnabled(widget.id, $0) }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    .padding(.vertical, 2)
                }
                .onMove { store.move(from: $0, to: $1) }
            }
            Text("Drag to reorder the tabs. A widget that is switched off also stops working in the background.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }
}
