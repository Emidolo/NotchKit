import Foundation
import Testing
@testable import NotchKit

@Test func macWallStateFromDefaultsOrNotification() {
    let empty = MacWall.State([:])
    #expect(empty.mirror && empty.volume == 0 && !empty.userPaused && empty.assignments.isEmpty)

    let mirrored = MacWall.State(["assignments": ["*": "111", "A": "222"], "mirror": true, "volume": NSNumber(value: Float(0.3)), "userPaused": true])
    #expect(mirrored.wallpaperID(forDisplay: "A") == "111")
    #expect(abs(mirrored.volume - 0.3) < 0.001)
    #expect(mirrored.userPaused)

    let perDisplay = MacWall.State(["assignments": ["*": "111", "A": "222"], "mirror": false])
    #expect(perDisplay.wallpaperID(forDisplay: "A") == "222")
    #expect(perDisplay.wallpaperID(forDisplay: "B") == "111")
}

@Test func macWallLibraryReadsPlayableProjectsInTitleOrder() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotchKitTests-\(UUID().uuidString)")
    func add(_ id: String, _ json: String?) throws {
        let folder = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let json { try Data(json.utf8).write(to: folder.appendingPathComponent("project.json")) }
    }
    try add("300", #"{"title":"zebra","type":"Video","preview":"preview.gif"}"#)
    try add("100", #"{"title":"Apple","type":"scene","preview":"preview.jpg"}"#)
    try add("200", #"{"type":"web"}"#)
    try add("400", #"{"title":"Windows only","type":"application"}"#)
    try add("500", "not json")
    try add("600", nil)

    let library = MacWall.library(at: root)
    #expect(library.map(\.id) == ["200", "100", "300"])
    #expect(library.map(\.title) == ["200", "Apple", "zebra"])
    #expect(library.map(\.kind) == ["web", "scene", "video"])
    #expect(library[1].preview?.path.hasSuffix("/100/preview.jpg") == true)
    #expect(library[0].preview == nil)
    #expect(MacWall.library(at: root.appendingPathComponent("missing")).isEmpty)
}

@Test func macWallCommandURLs() {
    #expect(MacWall.url("next").absoluteString == "macwall://next")
    #expect(MacWall.url("volume", ["value": "0.25"]).absoluteString == "macwall://volume?value=0.25")
    #expect(MacWall.url("set", ["id": "123", "display": "37D8-AB"]).absoluteString == "macwall://set?display=37D8-AB&id=123")
}
