import AppKit
import ImageIO
import SwiftUI

@MainActor extension Widget {
    static let wallpaper = Widget(id: "wallpaper", title: "Wallpaper", icon: "photo", indicator: {
        // Only for a pause the user asked for; MacWall's automatic pauses (fullscreen, sleep) stay quiet.
        WallpaperModel.shared.pausedByUser
            ? AnyView(Image(systemName: "pause.fill").font(.system(size: 10)).accessibilityLabel("Wallpaper paused")) : nil
    }) {
        AnyView(WallpaperView())
    }
}

/// MacWall (github.com/Emidolo/MacWall) stays a separate app. This reads its library and state from
/// disk and drives it through its `macwall://` URL scheme, so wallpapers keep playing if NotchKit quits.
enum MacWall {
    static let bundleID = "dev.macwall.MacWall"
    static let stateChanged = Notification.Name("dev.macwall.MacWall.stateChanged")
    static let repository = URL(string: "https://github.com/Emidolo/MacWall")!
    static let libraryRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MacWall/wallpapers", isDirectory: true)

    struct Wallpaper: Identifiable, Equatable {
        /// The folder name inside the library.
        let id: String
        let title: String
        /// "video", "web" or "scene".
        let kind: String
        let preview: URL?
    }

    /// MacWall's state, from its defaults domain or from a state-changed notification (both use these keys).
    struct State: Equatable {
        /// Display UUID, or "*" for all displays → wallpaper id.
        var assignments: [String: String]
        var mirror: Bool
        /// 0...1.
        var volume: Double
        var userPaused: Bool

        init(_ values: [String: Any]) {
            assignments = values["assignments"] as? [String: String] ?? [:]
            mirror = values["mirror"] as? Bool ?? true
            volume = (values["volume"] as? NSNumber)?.doubleValue ?? 0
            userPaused = values["userPaused"] as? Bool ?? false
        }

        func wallpaperID(forDisplay uuid: String) -> String? {
            mirror ? assignments["*"] : (assignments[uuid] ?? assignments["*"])
        }
    }

    /// Every playable wallpaper under `root`, in title order (the order MacWall's next/previous use).
    static func library(at root: URL) -> [Wallpaper] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return folders.compactMap { folder -> Wallpaper? in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("project.json")),
                  let project = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let kind = (project["type"] as? String ?? "").lowercased()
            guard ["video", "web", "scene"].contains(kind) else { return nil }
            let title = project["title"] as? String ?? ""
            return Wallpaper(id: folder.lastPathComponent, title: title.isEmpty ? folder.lastPathComponent : title, kind: kind,
                             preview: (project["preview"] as? String).map { folder.appendingPathComponent($0) })
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    static func url(_ command: String, _ query: [String: String] = [:]) -> URL {
        var parts = URLComponents()
        parts.scheme = "macwall"
        parts.host = command
        if !query.isEmpty { parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return parts.url!
    }
}

extension NSScreen {
    /// The identifier MacWall keys per-display wallpapers by.
    var displayUUID: String {
        let id = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "\(id)" }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

@MainActor @Observable
final class WallpaperModel {
    static let shared = WallpaperModel()

    private(set) var state = MacWall.State([:])
    private(set) var library: [MacWall.Wallpaper] = []
    private(set) var isRunning = false
    private(set) var isInstalled = false
    /// What the slider shows; follows MacWall except while being dragged.
    private(set) var volume = 0.0

    @ObservationIgnored private var volumeTask: Task<Void, Never>?
    @ObservationIgnored private var volumeBeforeMute = 0.5

    var current: MacWall.Wallpaper? {
        guard let screen = NSScreen.screens.first else { return nil }
        let id = state.wallpaperID(forDisplay: screen.displayUUID)
        return library.first { $0.id == id }
    }
    var pausedByUser: Bool { isRunning && state.userPaused }

    private init() {
        // MacWall announces every change, so nothing here polls.
        DistributedNotificationCenter.default().addObserver(forName: MacWall.stateChanged, object: nil, queue: .main) { [weak self] note in
            let values = note.userInfo as? [String: Any] ?? [:]
            MainActor.assumeIsolated { self?.apply(MacWall.State(values)) }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == MacWall.bundleID else { return }
                MainActor.assumeIsolated { self?.reload() }
            }
        }
        reload()
    }

    /// Re-reads everything from disk: whether MacWall is there, its saved state and its library.
    func reload() {
        isInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MacWall.bundleID) != nil
        isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: MacWall.bundleID).isEmpty
        library = MacWall.library(at: MacWall.libraryRoot)
        apply(MacWall.State(UserDefaults.standard.persistentDomain(forName: MacWall.bundleID) ?? [:]))
    }

    private func apply(_ new: MacWall.State) {
        state = new
        if volumeTask == nil { volume = new.volume }
        if new.volume > 0 { volumeBeforeMute = new.volume }
        // A wallpaper downloaded since the last look.
        if !library.contains(where: { new.assignments.values.contains($0.id) }) { library = MacWall.library(at: MacWall.libraryRoot) }
    }

    /// Sends a `macwall://` command. Does nothing unless MacWall is running, so a click never launches it by surprise.
    func send(_ command: String, _ query: [String: String] = [:]) {
        guard isRunning else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(MacWall.url(command, query), configuration: configuration)
    }

    func launch() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MacWall.bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: app, configuration: configuration)
    }

    func setVolume(_ value: Double) {
        volume = value
        // The slider fires continuously; send only once it settles.
        volumeTask?.cancel()
        volumeTask = Task {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            send("volume", ["value": String(format: "%.2f", value)])
            volumeTask = nil
        }
    }

    func toggleMute() {
        setVolume(volume > 0 ? 0 : volumeBeforeMute)
    }
}

// MARK: - View

struct WallpaperView: View {
    private let model = WallpaperModel.shared

    var body: some View {
        Group {
            if !model.isInstalled {
                VStack(spacing: 6) {
                    EmptyHint(icon: "photo", title: "MacWall isn't installed",
                              detail: "MacWall plays Wallpaper Engine wallpapers on your desktop.")
                    Link("github.com/Emidolo/MacWall", destination: MacWall.repository).font(.caption)
                }
            } else if !model.isRunning {
                VStack(spacing: 6) {
                    EmptyHint(icon: "photo", title: "MacWall isn't running", detail: "Launch it to control your wallpaper from here.")
                    Button("Launch MacWall") { model.launch() }
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    nowShowing.frame(width: 230)
                    libraryStrip
                }
            }
        }
        .controlSize(.small)
        // Each time the notch opens: picks up wallpapers added in MacWall meanwhile.
        .task { model.reload() }
    }

    private var nowShowing: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Thumbnail(url: model.current?.preview)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.current?.title ?? "No wallpaper set").font(.callout.weight(.medium)).lineLimit(2)
                    Text([model.current?.kind.capitalized, model.pausedByUser ? "Paused" : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                iconButton("backward.fill", "Previous wallpaper") { model.send("previous") }
                iconButton(model.pausedByUser ? "play.fill" : "pause.fill", model.pausedByUser ? "Resume wallpaper" : "Pause wallpaper") {
                    model.send("toggle")
                }
                iconButton("forward.fill", "Next wallpaper") { model.send("next") }
                Spacer(minLength: 0)
                iconButton(model.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", model.volume == 0 ? "Unmute" : "Mute") {
                    model.toggleMute()
                }
                Slider(value: Binding(get: { model.volume }, set: { model.setVolume($0) }), in: 0...1)
                    .frame(width: 84)
                    .accessibilityLabel("Wallpaper volume")
            }
        }
    }

    private var libraryStrip: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if model.library.isEmpty {
                Text("Your MacWall library is empty.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 6) {
                        ForEach(model.library) { tile($0) }
                    }
                    .padding(2)
                }
                .scrollIndicators(.never)
            }
            Button("Open MacWall Library") { model.send("open-library") }
                .help("Downloads, properties and settings live in MacWall.")
        }
    }

    private func tile(_ wallpaper: MacWall.Wallpaper) -> some View {
        Button { model.send("set", ["id": wallpaper.id]) } label: {
            Thumbnail(url: wallpaper.preview)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white, lineWidth: wallpaper == model.current ? 2 : 0))
        }
        .buttonStyle(.plain)
        .help(wallpaper.title)
        .accessibilityLabel(wallpaper.title)
        .contextMenu {
            Button("Set on All Displays") { model.send("set", ["id": wallpaper.id]) }
            if NSScreen.screens.count > 1 {
                ForEach(NSScreen.screens, id: \.displayUUID) { screen in
                    Button("Set on \(screen.localizedName)") { model.send("set", ["id": wallpaper.id, "display": screen.displayUUID]) }
                }
            }
        }
    }
}

/// A wallpaper preview, decoded small and off the main thread (previews can be large GIFs).
private struct Thumbnail: View {
    let url: URL?
    @State private var image: NSImage?
    private static let cache = NSCache<NSURL, NSImage>()

    var body: some View {
        ZStack {
            Color.white.opacity(0.08)
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
        }
        .task(id: url) { image = await Self.load(url) }
        .accessibilityHidden(true)
    }

    private static func load(_ url: URL?) async -> NSImage? {
        guard let url else { return nil }
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        let image = await Task.detached { () -> NSImage? in
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: 256]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: thumbnail, size: .zero)
        }.value
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}
