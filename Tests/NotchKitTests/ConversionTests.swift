import AppKit
import ImageIO
import PDFKit
import Testing
@testable import NotchKit

private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("NotchKitTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func pixelSize(_ url: URL) -> [Int]? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return [width, height]
}

private func samplePNG(in directory: URL, name: String = "sample", width: Int = 400, height: Int = 200) throws -> URL {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(.init(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    // A red marker in the bottom-left corner, so rotation is visible.
    context.setFillColor(.init(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width / 4, height: height / 4))
    let url = directory.appendingPathComponent("\(name).png")
    try Conversion.write(context.makeImage()!, to: url, as: .png, quality: 1)
    return url
}

@Test func kindsFromFileNames() {
    #expect(Kind(URL(fileURLWithPath: "/a/clip.MKV")) == .video)
    #expect(Kind(URL(fileURLWithPath: "/a/clip.mp4")) == .video)
    #expect(Kind(URL(fileURLWithPath: "/a/song.flac")) == .audio)
    #expect(Kind(URL(fileURLWithPath: "/a/song.m4a")) == .audio)
    #expect(Kind(URL(fileURLWithPath: "/a/scan.pdf")) == .pdf)
    #expect(Kind(URL(fileURLWithPath: "/a/photo.heic")) == .image)
    #expect(Kind(URL(fileURLWithPath: "/a/notes.txt")) == nil)
    #expect(Kind(URL(fileURLWithPath: "/a/folder")) == nil)
}

@Test func mixedBatchesOfferOnlySharedFormats() {
    #expect(Conversion.commonFormats([.image, .pdf]) == [.png, .jpg, .pdf])
    #expect(Conversion.commonFormats([.video, .audio]) == [.mp3, .m4a, .wav, .flac, .ogg])
    #expect(Conversion.commonFormats([.image, .audio]).isEmpty)
    #expect(Conversion.commonFormats([]).isEmpty)
}

@Test func freeURLNeverPointsAtAnExistingFile() throws {
    let directory = try scratch()
    #expect(Conversion.freeURL(in: directory, name: "a", ext: "png").lastPathComponent == "a.png")
    try Data().write(to: directory.appendingPathComponent("a.png"))
    try Data().write(to: directory.appendingPathComponent("a 2.png"))
    #expect(Conversion.freeURL(in: directory, name: "a", ext: "png").lastPathComponent == "a 3.png")
}

@Test func ffmpegProgressLines() {
    #expect(Conversion.progressSeconds("out_time_us=1500000") == 1.5)
    #expect(Conversion.progressSeconds("out_time_us=N/A") == nil)
    #expect(Conversion.progressSeconds("frame=12") == nil)
}

@Test func imagesConvertAndShrinkButNeverGrow() throws {
    let directory = try scratch()
    let png = try samplePNG(in: directory)
    for format in [Format.jpg, .heic, .tiff, .gif, .bmp, .png] {
        let output = directory.appendingPathComponent("out.\(format.rawValue)")
        try Conversion.image(png, to: output, as: format.imageType!, quality: 0.8, maxPixel: 100)
        #expect(pixelSize(output) == [100, 50], "\(format)")
    }
    let big = directory.appendingPathComponent("big.jpg")
    try Conversion.image(png, to: big, as: .jpeg, quality: 0.8, maxPixel: 5000)
    #expect(pixelSize(big) == [400, 200])
}

@Test func pdfMergeAndRasterize() throws {
    let directory = try scratch()
    let first = try samplePNG(in: directory, name: "one")
    let second = try samplePNG(in: directory, name: "two", width: 200, height: 300)
    let pdf = directory.appendingPathComponent("images.pdf")
    try Conversion.makePDF(from: [first, second], to: pdf)

    // Merging that PDF with another image appends pages in order.
    let merged = directory.appendingPathComponent("merged.pdf")
    try Conversion.makePDF(from: [pdf, first], to: merged)
    let document = try #require(PDFDocument(url: merged))
    #expect(document.pageCount == 3)

    // Turn the middle page on its side to check rotated pages come out with swapped dimensions.
    document.page(at: 1)!.rotation = 90
    let rotated = directory.appendingPathComponent("rotated.pdf")
    #expect(document.write(to: rotated))

    let pages = try Conversion.rasterize(rotated, into: directory, name: "page", format: .png, dpi: 144, quality: 1) { _ in }
    #expect(pages.map(\.lastPathComponent) == ["page-1.png", "page-2.png", "page-3.png"])
    let points = (0..<3).map { document.page(at: $0)!.bounds(for: .cropBox).size }
    print("rasterized pages:", pages.map(\.path))
    #expect(pixelSize(pages[0]) == [Int(points[0].width * 2), Int(points[0].height * 2)])
    let upright = PDFDocument(url: merged)!.page(at: 1)!.bounds(for: .cropBox).size
    #expect(pixelSize(pages[1]) == [Int(upright.height * 2), Int(upright.width * 2)])
}

@Test func toolOutputKeepsLineOrderAndReportsFailure() async {
    let ok = await runTool(URL(fileURLWithPath: "/usr/bin/printf"), ["a\\n\\nb\\n"])
    #expect(ok.status == 0)
    #expect(ok.output == "a\n\nb")
    let missing = await runTool(URL(fileURLWithPath: "/nonexistent/tool"), [])
    #expect(missing.status == -1)
    let failing = await runTool(URL(fileURLWithPath: "/bin/ls"), ["/nonexistent"])
    #expect(failing.status != 0 && !failing.error.isEmpty)
}

/// Runs every ffmpeg recipe against a generated two-second clip. Skipped when ffmpeg isn't installed.
@Test func everyFFmpegRecipeProducesAFile() async throws {
    guard let ffmpeg = Tool.find("ffmpeg") else { return }
    let directory = try scratch()
    let clip = directory.appendingPathComponent("clip.mp4")
    // 321px wide on purpose: odd sizes break H.264 unless the recipe rounds them.
    let made = await runTool(ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "testsrc=duration=2:size=321x240:rate=24",
                                      "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-c:v", "mpeg4", "-c:a", "aac", clip.path])
    try #require(made.status == 0, "\(made.error)")

    for format in Kind.video.outputs {
        let output = directory.appendingPathComponent("out.\(format.rawValue)")
        let result = await runTool(ffmpeg, Conversion.ffmpegArguments(input: clip.path, output: output.path, format: format))
        #expect(result.status == 0, "\(format): \(result.error)")
        #expect(result.output.components(separatedBy: "\n").contains { Conversion.progressSeconds($0) != nil }, "\(format) reported no progress")
        let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
        #expect(size > 500, "\(format) wrote \(size) bytes")
    }

    // -n: an existing file is refused, not overwritten.
    let existing = directory.appendingPathComponent("out.mp3")
    let before = try Data(contentsOf: existing)
    try Data("mine".utf8).write(to: existing)
    _ = await runTool(ffmpeg, Conversion.ffmpegArguments(input: clip.path, output: existing.path, format: .mp3))
    #expect(try Data(contentsOf: existing) == Data("mine".utf8))
    #expect(before.count > 500)
}

/// The whole pipeline through the view model: queue, per-file state, output naming, originals left alone.
@MainActor @Test func modelConvertsABatchNextToTheOriginals() async throws {
    let directory = try scratch()
    let image = try samplePNG(in: directory, name: "photo")
    let original = try Data(contentsOf: image)
    let model = ConverterModel()
    model.outputDirectory = nil

    func run() async {
        model.convert()
        while model.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
    }
    func outputs(_ item: ConvertItem) -> [String] {
        if case .done(let urls) = item.state { urls.map(\.lastPathComponent) } else { ["\(item.state)"] }
    }

    // Same extension in, same extension out: the copy gets a new name.
    model.add([image, directory.appendingPathComponent("notes.txt")])
    #expect(model.items.count == 1)
    model.format = .png
    await run()
    #expect(outputs(model.items[0]) == ["photo 2.png"])
    #expect(try Data(contentsOf: image) == original)

    // Changing the format re-queues finished files.
    model.format = .jpg
    #expect(model.canConvert)
    await run()
    #expect(outputs(model.items[0]) == ["photo.jpg"])

    // Image + PDF share "one PDF".
    model.format = .pdf
    await run()
    let pdf = directory.appendingPathComponent("photo.pdf")
    model.add([pdf])
    #expect(model.formats == [.png, .jpg, .pdf])
    await run()
    #expect(outputs(model.items[1]) == ["photo merged.pdf"])
    #expect(PDFDocument(url: directory.appendingPathComponent("photo merged.pdf"))?.pageCount == 2)

    // Video to audio through ffmpeg, when it is installed.
    guard let ffmpeg = Tool.find("ffmpeg") else { return }
    let clip = directory.appendingPathComponent("clip.mov")
    let made = await runTool(ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "testsrc=duration=1:size=320x240:rate=24",
                                      "-f", "lavfi", "-i", "sine=frequency=440:duration=1", clip.path])
    try #require(made.status == 0, "\(made.error)")
    model.clear()
    model.add([clip])
    #expect(model.format == .mp4)
    model.format = .mp3
    await run()
    #expect(outputs(model.items[0]) == ["clip.mp3"])
    // No hidden partial files left behind.
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".NotchKit") }.isEmpty)
}
