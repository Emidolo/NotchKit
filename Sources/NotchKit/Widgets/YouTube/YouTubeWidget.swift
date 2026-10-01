import AppKit
import SwiftUI

@MainActor extension Widget {
    static let youTube = Widget(id: "youtube", title: "YouTube", icon: "arrow.down.circle", indicator: {
        YouTubeModel.shared.progress.map { AnyView(ProgressRing(fraction: $0)) }
    }) {
        AnyView(YouTubeView())
    }
}

enum DownloadMode: Equatable {
    /// "best", or a maximum height such as "1080".
    case video(quality: String)
    /// "mp3" or "m4a".
    case audio(format: String)
}

/// Pure helpers around yt-dlp: recognising links, building its arguments, reading its output.
enum YouTube {
    static let qualities = ["best", "2160", "1440", "1080", "720", "480"]
    static let audioFormats = ["mp3", "m4a"]

    /// The video link in `text`, if `text` is exactly one YouTube video URL. This is the gate for
    /// whatever lands on the clipboard, so anything that isn't plainly a video link is rejected.
    static func link(in text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains(where: \.isWhitespace), let parts = URLComponents(string: text),
              parts.scheme == "https" || parts.scheme == "http", var host = parts.host?.lowercased() else { return nil }
        for prefix in ["www.", "m."] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        let isVideo = switch host {
        case "youtu.be":
            parts.path.count > 1
        case "youtube.com", "music.youtube.com":
            parts.path.hasPrefix("/shorts/") || parts.path.hasPrefix("/live/")
                || (parts.path == "/watch" && parts.queryItems?.contains { $0.name == "v" && $0.value?.isEmpty == false } == true)
        default:
            false
        }
        return isVideo ? parts.url : nil
    }

    static func metadataArguments(_ url: URL) -> [String] {
        ["--no-playlist", "--no-warnings", "--print", "%(title)s", "--print", "%(thumbnail)s", "--print", "%(duration_string)s",
         "--", url.absoluteString]
    }

    /// `temp` holds the partial files, so a cancelled download leaves nothing in `directory`.
    static func downloadArguments(_ url: URL, mode: DownloadMode, directory: URL, temp: URL, ffmpeg: URL?) -> [String] {
        var arguments = ["--no-playlist", "--no-warnings", "--newline", "--progress",
                         "--progress-template", "download:NKP %(progress._percent_str)s",
                         "--print", "before_dl:NKT %(title)s", "--print", "after_move:NKF %(filepath)s",
                         "-P", "home:\(directory.path)", "-P", "temp:\(temp.path)", "-o", "%(title)s.%(ext)s"]
        if let ffmpeg { arguments += ["--ffmpeg-location", ffmpeg.deletingLastPathComponent().path] }
        switch mode {
        case .video(let quality):
            // Resolution first, then the codecs QuickTime plays (H.264/AAC) when YouTube offers them at that size.
            arguments += ["-S", (quality == "best" ? "res" : "res:\(quality)") + ",vcodec:h264,acodec:aac", "--merge-output-format", "mp4"]
        case .audio(let format):
            arguments += ["-x", "--audio-format", format, "--audio-quality", "0", "--embed-thumbnail", "--embed-metadata"]
        }
        return arguments + ["--", url.absoluteString]
    }

    enum Event: Equatable {
        case progress(Double), title(String), file(String)
    }

    /// Decodes the lines requested by `downloadArguments`.
    static func event(_ line: String) -> Event? {
        let value = String(line.dropFirst(4))
        switch line.prefix(4) {
        case "NKP ": return Double(value.trimmingCharacters(in: CharacterSet(charactersIn: " %"))).map { .progress($0 / 100) }
        case "NKT ": return .title(value)
        case "NKF ": return .file(value)
        default: return nil
        }
    }
}

@MainActor @Observable
final class Download: Identifiable {
    enum State {
        case waiting, running(Double), done(URL), failed(String)
    }

    let url: URL
    let mode: DownloadMode
    var title: String
    var state = State.waiting
    @ObservationIgnored fileprivate var file: URL?
    @ObservationIgnored fileprivate var task: Task<Void, Never>?

    init(url: URL, mode: DownloadMode, title: String) {
        self.url = url
        self.mode = mode
        self.title = title
    }
}

@MainActor @Observable
final class YouTubeModel {
    static let shared = YouTubeModel()

    /// A link waiting for "video or audio?", with whatever is known about it so far.
    struct Prompt {
        let url: URL
        var title: String?
        var thumbnail: URL?
        var duration: String?
        var error: String?
    }

    private(set) var prompt: Prompt?
    private(set) var downloads: [Download] = []
    /// One line of feedback under the link field.
    private(set) var status: String?
    var link = ""

    var quality = UserDefaults.standard.string(forKey: "youtubeQuality") ?? "1080" {
        didSet { UserDefaults.standard.set(quality, forKey: "youtubeQuality") }
    }
    var audioFormat = UserDefaults.standard.string(forKey: "youtubeAudioFormat") ?? "mp3" {
        didSet { UserDefaults.standard.set(audioFormat, forKey: "youtubeAudioFormat") }
    }
    var directory = UserDefaults.standard.string(forKey: "youtubeDirectory").map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] {
        didSet { UserDefaults.standard.set(directory.path, forKey: "youtubeDirectory") }
    }
    var detectClipboard = UserDefaults.standard.object(forKey: "clipboardDetection") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(detectClipboard, forKey: "clipboardDetection")
            startWatchingClipboard()
        }
    }

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastChangeCount = 0

    /// The running download's progress; nil when idle.
    // ponytail: yt-dlp reports video and audio streams separately, so the ring runs 0→100 twice for a video.
    var progress: Double? {
        for download in downloads { if case .running(let fraction) = download.state { return fraction } }
        return nil
    }

    // MARK: Clipboard

    /// Starts or stops the poll to match the setting. Whatever is already on the clipboard is ignored.
    func startWatchingClipboard() {
        timer?.invalidate()
        timer = nil
        guard detectClipboard else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        // The pasteboard has no change notification. One integer compare a second is the cheapest way to follow it.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkClipboard() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func checkClipboard() {
        let count = NSPasteboard.general.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard let text = NSPasteboard.general.string(forType: .string), let url = YouTube.link(in: text),
              url != prompt?.url, !downloads.contains(where: { $0.url == url }) else { return }
        offer(url)
        NotchController.shared.selected = Widget.youTube.id
        NotchController.shared.peek()
    }

    // MARK: Prompt

    func submitLink() {
        guard let url = YouTube.link(in: link) else { return status = "That isn't a YouTube video link." }
        link = ""
        offer(url)
    }

    private func offer(_ url: URL) {
        status = nil
        prompt = Prompt(url: url)
        guard let ytdlp = Tool.find("yt-dlp") else { return }
        Task {
            let result = await runTool(ytdlp, YouTube.metadataArguments(url))
            guard prompt?.url == url else { return }
            let lines = result.output.components(separatedBy: "\n")
            if result.status == 0, lines.count >= 3 {
                prompt?.title = lines[0]
                prompt?.thumbnail = URL(string: lines[1])
                // Under a minute yt-dlp prints bare seconds ("19").
                prompt?.duration = lines[2].contains(":") ? lines[2] : "0:" + (lines[2].count < 2 ? "0" : "") + lines[2]
            } else {
                prompt?.error = Tool.lastError(result, fallback: "Couldn't read this video")
            }
        }
    }

    func dismissPrompt() { prompt = nil }

    func download(_ mode: DownloadMode) {
        guard let prompt else { return }
        downloads.append(Download(url: prompt.url, mode: mode, title: prompt.title ?? prompt.url.absoluteString))
        self.prompt = nil
        startNext()
    }

    // MARK: Queue

    /// Cancels a running download, or takes a waiting or finished one off the list.
    func remove(_ download: Download) {
        download.task?.cancel()
        downloads.removeAll { $0 === download }
    }

    /// One download at a time, in the order they were added.
    private func startNext() {
        guard progress == nil, let next = downloads.first(where: { if case .waiting = $0.state { true } else { false } }) else { return }
        next.state = .running(0)
        next.task = Task {
            await run(next)
            startNext()
        }
    }

    private func run(_ download: Download) async {
        guard let ytdlp = Tool.find("yt-dlp") else { return download.state = .failed("yt-dlp is not installed") }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("NotchKit-download-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let arguments = YouTube.downloadArguments(download.url, mode: download.mode, directory: directory, temp: temp, ffmpeg: Tool.find("ffmpeg"))
        let result = await runTool(ytdlp, arguments) { line in
            switch YouTube.event(line) {
            case .progress(let fraction): download.state = .running(fraction)
            case .title(let title): download.title = title
            case .file(let path): download.file = URL(fileURLWithPath: path)
            case nil: break
            }
        }
        if result.status == 0, let file = download.file {
            download.state = .done(file)
        } else {
            // Also reached after a cancel, when the item is already off the list.
            download.state = .failed(Tool.lastError(result, fallback: "Download failed"))
        }
    }

    // MARK: Settings

    func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = directory
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { directory = url }
        NotchController.shared.expand()
    }

    /// yt-dlp breaks whenever YouTube changes something, so updating it is one click.
    func updateYtDlp() {
        guard let ytdlp = Tool.find("yt-dlp") else { return }
        status = "Updating yt-dlp…"
        Task {
            // A Homebrew copy refuses to update itself; anything else knows how.
            let fromHomebrew = ytdlp.resolvingSymlinksInPath().path.contains("/Cellar/")
            let result = if fromHomebrew, let brew = Tool.find("brew") {
                await runTool(brew, ["upgrade", "yt-dlp"])
            } else {
                await runTool(ytdlp, ["-U"])
            }
            let version = await runTool(ytdlp, ["--version"]).output
            status = result.status == 0 ? "yt-dlp is up to date (\(version))." : Tool.lastError(result, fallback: "Update failed")
        }
    }
}

// MARK: - View

struct YouTubeView: View {
    @Bindable private var model = YouTubeModel.shared

    var body: some View {
        let _ = ToolInstaller.shared.revision
        if Tool.find("yt-dlp") == nil {
            VStack(spacing: 6) {
                EmptyHint(icon: "arrow.down.circle", title: "yt-dlp is needed", detail: "It does the downloading. NotchKit installs it with Homebrew.")
                InstallButton(package: "yt-dlp")
            }
            .controlSize(.small)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                toolbar
                if Tool.find("ffmpeg") == nil {
                    HStack(spacing: 6) {
                        Text("ffmpeg is needed to join video and audio.").font(.caption).foregroundStyle(.orange)
                        InstallButton(package: "ffmpeg")
                    }
                } else if let status = model.status {
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(status)
                }
                if model.prompt == nil && model.downloads.isEmpty {
                    Text(model.detectClipboard ? "Copy a YouTube link anywhere and it appears here." : "Paste a YouTube link above.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 4) {
                            if let prompt = model.prompt { promptCard(prompt) }
                            ForEach(model.downloads) { DownloadRow(download: $0, model: model) }
                        }
                    }
                }
            }
            .controlSize(.small)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            TextField("Paste a YouTube link", text: $model.link)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.submitLink() }
            Picker("Video quality", selection: $model.quality) {
                ForEach(YouTube.qualities, id: \.self) { Text($0 == "best" ? "Best" : "\($0)p").tag($0) }
            }
            .labelsHidden().fixedSize().help("Video quality")
            Picker("Audio format", selection: $model.audioFormat) {
                ForEach(YouTube.audioFormats, id: \.self) { Text($0.uppercased()).tag($0) }
            }
            .labelsHidden().fixedSize().help("Audio format")
            Menu {
                Toggle("Detect Copied Links", isOn: $model.detectClipboard)
                Button("Save to: \(model.directory.lastPathComponent)…") { model.pickDirectory() }
                Divider()
                Button("Update yt-dlp") { model.updateYtDlp() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Download options")
        }
    }

    private func promptCard(_ prompt: YouTubeModel.Prompt) -> some View {
        HStack(spacing: 8) {
            AsyncImage(url: prompt.thumbnail) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: { Color.white.opacity(0.08) }
                .frame(width: 64, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(prompt.title ?? prompt.url.absoluteString).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(prompt.error ?? prompt.duration ?? "Looking up…")
                    .font(.caption).foregroundStyle(prompt.error == nil ? Color.secondary : Color.red).lineLimit(1)
                    .help(prompt.error ?? "")
            }
            Spacer(minLength: 4)
            Button("Video") { model.download(.video(quality: model.quality)) }
                .help("Download video (\(model.quality == "best" ? "best quality" : model.quality + "p"), MP4)")
            Button("Audio") { model.download(.audio(format: model.audioFormat)) }
                .help("Download audio only (\(model.audioFormat.uppercased()))")
            iconButton("xmark", "Dismiss") { model.dismissPrompt() }
        }
        .padding(6)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct DownloadRow: View {
    let download: Download
    let model: YouTubeModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: { if case .audio = download.mode { "music.note" } else { "film" } }())
                .frame(width: 16).foregroundStyle(.secondary)
            Text(download.title).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            switch download.state {
            case .waiting:
                Text("Waiting").font(.caption).foregroundStyle(.secondary)
                iconButton("xmark", "Remove") { model.remove(download) }
            case .running(let fraction):
                ProgressView(value: fraction).frame(width: 70)
                Text("\(Int(fraction * 100))%").font(.caption.monospacedDigit()).frame(width: 30, alignment: .trailing)
                iconButton("xmark", "Cancel") { model.remove(download) }
            case .done(let file):
                iconButton("magnifyingglass", "Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                iconButton("xmark", "Remove from list") { model.remove(download) }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).lineLimit(1).help(message)
                iconButton("xmark", "Remove") { model.remove(download) }
            }
        }
        .font(.callout)
        .frame(height: 22)
    }
}
