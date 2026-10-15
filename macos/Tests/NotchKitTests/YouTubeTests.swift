import Foundation
import Testing
@testable import NotchKit

@Test func recognisesOnlyYouTubeVideoLinks() {
    let accepted = [
        "https://www.youtube.com/watch?v=jNQXAC9IVRw",
        "  https://youtube.com/watch?v=jNQXAC9IVRw&list=PL123&t=4s\n",
        "https://youtu.be/jNQXAC9IVRw?si=abc",
        "https://www.youtube.com/shorts/abc123",
        "https://m.youtube.com/watch?v=abc",
        "https://music.youtube.com/watch?v=abc",
        "http://www.youtube.com/live/abc",
    ]
    for text in accepted { #expect(YouTube.link(in: text) != nil, "\(text)") }

    let rejected = [
        "",
        "watch this https://youtu.be/jNQXAC9IVRw",
        "https://www.youtube.com/",
        "https://www.youtube.com/watch",
        "https://www.youtube.com/watch?v=",
        "https://www.youtube.com/@channel",
        "https://youtu.be/",
        "https://notyoutube.com/watch?v=abc",
        "https://youtube.com.evil.example/watch?v=abc",
        "https://example.com/?u=https://youtu.be/abc",
        "--exec=rm https://youtu.be/abc",
        "file:///watch?v=abc",
        "youtu.be/abc",
    ]
    for text in rejected { #expect(YouTube.link(in: text) == nil, "\(text)") }
}

@Test func readsYtDlpOutputLines() {
    #expect(YouTube.event("NKP  45.5%") == .progress(0.455))
    #expect(YouTube.event("NKP 100.0%") == .progress(1))
    #expect(YouTube.event("NKP   N/A%") == nil)
    #expect(YouTube.event("NKT Me at the zoo") == .title("Me at the zoo"))
    #expect(YouTube.event("NKF /tmp/Me at the zoo.mp4") == .file("/tmp/Me at the zoo.mp4"))
    #expect(YouTube.event("[download] Destination: x") == nil)
    #expect(YouTube.event("") == nil)
}

@Test func downloadArgumentsPerMode() {
    let url = URL(string: "https://youtu.be/abc")!
    let home = URL(fileURLWithPath: "/dl"), temp = URL(fileURLWithPath: "/tmp/x")
    func arguments(_ mode: DownloadMode) -> String {
        YouTube.downloadArguments(url, mode: mode, directory: home, temp: temp, ffmpeg: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")).joined(separator: " ")
    }
    let video = arguments(.video(quality: "1080"))
    #expect(video.contains("-S res:1080,vcodec:h264,acodec:aac --merge-output-format mp4"))
    #expect(video.contains("-P home:/dl -P temp:/tmp/x"))
    #expect(video.contains("--ffmpeg-location /opt/homebrew/bin"))
    #expect(video.contains("--no-playlist"))
    #expect(video.hasSuffix("-- https://youtu.be/abc"))
    #expect(arguments(.video(quality: "best")).contains("-S res,vcodec:h264"))
    let audio = arguments(.audio(format: "m4a"))
    #expect(audio.contains("-x --audio-format m4a --audio-quality 0 --embed-thumbnail --embed-metadata"))
    #expect(!audio.contains("--merge-output-format"))
}

/// Real downloads through the view model. Needs the network, so it only runs when asked:
/// NOTCHKIT_NETWORK_TESTS=1 make test
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["NOTCHKIT_NETWORK_TESTS"] != nil))
func modelDownloadsVideoAndAudio() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NotchKitTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let saved = UserDefaults.standard.string(forKey: "youtubeDirectory")
    defer { UserDefaults.standard.set(saved, forKey: "youtubeDirectory") }
    let model = YouTubeModel()
    model.directory = directory

    func wait(_ what: String, until done: () -> Bool) async throws {
        for _ in 0..<600 where !done() { try await Task.sleep(for: .milliseconds(100)) }
        try #require(done(), "timed out waiting for \(what)")
    }
    func finished(_ download: Download) -> Bool {
        switch download.state { case .done, .failed: true; default: false }
    }

    model.link = "not a link"
    model.submitLink()
    #expect(model.prompt == nil && model.status != nil)

    for mode in [DownloadMode.video(quality: "480"), .audio(format: "mp3")] {
        model.link = "https://www.youtube.com/watch?v=jNQXAC9IVRw"
        model.submitLink()
        try await wait("metadata") { model.prompt?.title != nil || model.prompt?.error != nil }
        #expect(model.prompt?.title == "Me at the zoo")
        #expect(model.prompt?.thumbnail != nil)
        model.download(mode)
        #expect(model.prompt == nil)
        let download = try #require(model.downloads.last)
        try await wait("download") { finished(download) }
        guard case .done(let file) = download.state else { Issue.record("\(mode): \(download.state)"); continue }
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(file.deletingLastPathComponent().resolvingSymlinksInPath() == directory.resolvingSymlinksInPath())
        #expect(file.pathExtension == (mode == .audio(format: "mp3") ? "mp3" : "mp4"))
        print("downloaded:", file.lastPathComponent, (try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) ?? 0)
    }
    #expect(model.progress == nil)

    // Cancelling mid-download leaves nothing behind in the destination.
    let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    model.link = "https://www.youtube.com/watch?v=aqz-KE-bpKQ"
    model.submitLink()
    model.download(.video(quality: "1080"))
    let download = try #require(model.downloads.last)
    try await wait("progress") { if case .running(let f) = download.state { f > 0 } else { finished(download) } }
    model.remove(download)
    try await Task.sleep(for: .seconds(2))
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == before)
}
