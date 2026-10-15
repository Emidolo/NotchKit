import AppKit
import SwiftUI

@MainActor extension Widget {
    static let music = Widget(id: "music", title: "Music", icon: "music.note") {
        AnyView(MusicView())
    }
}

enum Player: String, CaseIterable, Identifiable {
    case spotify = "Spotify", music = "Music"

    var id: String { rawValue }
    var bundleID: String { self == .spotify ? "com.spotify.client" : "com.apple.Music" }
    /// Posted by the player whenever the track or play state changes, so nothing has to poll.
    var notification: Notification.Name {
        .init(self == .spotify ? "com.spotify.client.PlaybackStateChanged" : "com.apple.Music.playerInfo")
    }
    // `tell application` launches the target, so every script is guarded by this.
    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    /// Music hands artwork over as raw data, which the script writes here. Spotify gives a URL instead.
    static let artworkFile = FileManager.default.temporaryDirectory.appendingPathComponent("NotchKit-artwork")

    /// Returns lines: state, volume, then (unless stopped) title, artist and, for Spotify, the artwork URL.
    var stateScript: String {
        switch self {
        case .spotify: """
            tell application "Spotify"
                set r to (player state as text) & linefeed & sound volume
                if player state is not stopped then
                    set t to current track
                    set r to r & linefeed & name of t & linefeed & artist of t & linefeed & artwork url of t
                end if
                return r
            end tell
            """
        case .music: """
            set art to missing value
            tell application "Music"
                set r to (player state as text) & linefeed & sound volume
                if player state is not stopped then
                    set t to current track
                    set r to r & linefeed & name of t & linefeed & artist of t
                    try
                        set art to raw data of artwork 1 of t
                    end try
                end if
            end tell
            set f to open for access POSIX file "\(Player.artworkFile.path)" with write permission
            set eof f to 0
            if art is not missing value then write art to f
            close access f
            return r
            """
        }
    }
}

/// Runs an AppleScript out of process, so a slow player or a permission prompt never blocks the notch.
/// Returns stdout, or nil if the script failed (player refused, or Automation permission denied).
private func osascript(_ source: String) async -> String? {
    let result = await runTool(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", source])
    return result.status == 0 ? result.output : nil
}

@MainActor @Observable
final class MusicModel {
    static let shared = MusicModel()

    private(set) var player: Player?
    private(set) var title = ""
    private(set) var artist = ""
    private(set) var isPlaying = false
    private(set) var artwork: NSImage?
    /// The player's own volume, 0...100.
    private(set) var volume = 50.0
    /// A player is running but would not answer: Automation permission is missing.
    private(set) var blocked = false

    @ObservationIgnored private var artworkURL = ""
    @ObservationIgnored private var volumeTask: Task<Void, Never>?

    private init() {
        for player in Player.allCases {
            DistributedNotificationCenter.default().addObserver(forName: player.notification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
        }
    }

    func refresh() async {
        var states: [(player: Player, lines: [String])] = []
        var failed = false
        for player in Player.allCases where player.isRunning {
            if let lines = await osascript(player.stateScript)?.components(separatedBy: "\n"), lines.count >= 2 {
                states.append((player, lines))
            } else {
                failed = true
            }
        }
        blocked = failed
        // Whoever is playing wins; otherwise stay with the player already shown.
        guard let (player, lines) = states.first(where: { $0.lines[0] == "playing" })
            ?? states.first(where: { $0.player == self.player }) ?? states.first
        else { return self.player = nil }

        self.player = player
        isPlaying = lines[0] == "playing"
        if volumeTask == nil { volume = Double(lines[1]) ?? volume }
        title = lines.count > 2 ? lines[2] : ""
        artist = lines.count > 3 ? lines[3] : ""

        if player == .music {
            artworkURL = ""
            artwork = NSImage(contentsOf: Player.artworkFile)
        } else {
            let url = lines.count > 4 ? lines[4] : ""
            guard url != artworkURL else { return }
            artworkURL = url
            artwork = nil
            if let remote = URL(string: url), let (data, _) = try? await URLSession.shared.data(from: remote), artworkURL == url {
                artwork = NSImage(data: data)
            }
        }
    }

    /// `command` is AppleScript both players understand: "playpause", "next track", "previous track".
    func send(_ command: String) {
        guard let player, player.isRunning else { return }
        Task {
            _ = await osascript("tell application \"\(player.rawValue)\" to \(command)")
            await refresh()
        }
    }

    func setVolume(_ value: Double) {
        volume = value
        // The slider fires continuously; send only once it settles.
        volumeTask?.cancel()
        volumeTask = Task {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let player, player.isRunning else { return }
            _ = await osascript("tell application \"\(player.rawValue)\" to set sound volume to \(Int(value))")
            volumeTask = nil
        }
    }
}

struct MusicView: View {
    private let model = MusicModel.shared

    var body: some View {
        Group {
            if let player = model.player {
                nowPlaying(player)
            } else {
                idle
            }
        }
        // Each time the notch opens: picks up volume or track changes that sent no notification.
        .task { await model.refresh() }
    }

    private func nowPlaying(_ player: Player) -> some View {
        HStack(spacing: 16) {
            Group {
                if let artwork = model.artwork {
                    Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note").font(.system(size: 30)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.white.opacity(0.08))
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.title.isEmpty ? "Nothing playing" : model.title).font(.headline).lineLimit(1)
                Text([model.artist, player.rawValue].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    control("backward.fill", "Previous") { model.send("previous track") }
                    control(model.isPlaying ? "pause.fill" : "play.fill", model.isPlaying ? "Pause" : "Play", size: 24) {
                        model.send("playpause")
                    }
                    control("forward.fill", "Next") { model.send("next track") }
                    Spacer()
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { model.volume }, set: { model.setVolume($0) }), in: 0...100)
                        .controlSize(.small)
                        .frame(width: 150)
                        .accessibilityLabel("\(player.rawValue) volume")
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func control(_ icon: String, _ label: String, size: CGFloat = 16, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size)).frame(width: 40, height: 36).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private var idle: some View {
        VStack(spacing: 6) {
            EmptyHint(icon: model.blocked ? "lock" : "music.note",
                      title: model.blocked ? "Permission needed" : "No player running",
                      detail: model.blocked
                          ? "Allow NotchKit to control your player in System Settings → Privacy & Security → Automation."
                          : "Open Spotify or Music to control it from here.")
            if !model.blocked {
                HStack {
                    ForEach(Player.allCases.filter { $0.appURL != nil }) { player in
                        Button("Open \(player.rawValue)") {
                            NSWorkspace.shared.openApplication(at: player.appURL!, configuration: .init())
                        }
                    }
                }
                .controlSize(.small)
            }
        }
    }
}
