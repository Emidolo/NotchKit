import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// What an input file is, which decides what it can become.
enum Kind: Sendable {
    case image, pdf, video, audio

    // Containers the system's type database doesn't always classify.
    private static let videoExtensions: Set = ["mkv", "webm", "avi", "flv", "wmv", "ts"]
    private static let audioExtensions: Set = ["ogg", "opus", "flac", "wma"]

    init?(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        if ext == "pdf" {
            self = .pdf
        } else if Kind.videoExtensions.contains(ext) || type?.conforms(to: .movie) == true {
            self = .video
        } else if Kind.audioExtensions.contains(ext) || type?.conforms(to: .audio) == true {
            self = .audio
        } else if type?.conforms(to: .image) == true {
            self = .image
        } else {
            return nil
        }
    }

    var icon: String {
        switch self {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .video: "film"
        case .audio: "waveform"
        }
    }

    var outputs: [Format] {
        switch self {
        case .image: [.png, .jpg, .heic, .webp, .tiff, .gif, .bmp, .pdf]
        case .pdf: [.png, .jpg, .pdf]
        case .video: [.mp4, .mov, .mkv, .webm, .gif, .mp3, .m4a, .wav, .flac, .ogg]
        case .audio: [.mp3, .m4a, .wav, .flac, .ogg]
        }
    }
}

/// An output format. The raw value is the file extension.
enum Format: String, Identifiable, Sendable {
    case png, jpg, heic, webp, tiff, gif, bmp, pdf
    case mp4, mov, mkv, webm
    case mp3, m4a, wav, flac, ogg

    var id: String { rawValue }

    /// The type ImageIO writes; nil for formats it can't encode.
    var imageType: UTType? {
        switch self {
        case .png: .png
        case .jpg: .jpeg
        case .heic: .heic
        case .tiff: .tiff
        case .gif: .gif
        case .bmp: .bmp
        default: nil
        }
    }

    var isImage: Bool { imageType != nil || self == .webp }
    var hasQuality: Bool { [.jpg, .heic, .webp].contains(self) }
}

struct Failure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// The conversion engines. Everything here is synchronous and safe to call off the main thread.
enum Conversion {
    /// Formats every file in the batch can become, in the first file's order.
    static func commonFormats(_ kinds: [Kind]) -> [Format] {
        guard let first = kinds.first else { return [] }
        return first.outputs.filter { format in kinds.allSatisfy { $0.outputs.contains(format) } }
    }

    /// A path that doesn't exist yet: "name.ext", then "name 2.ext", "name 3.ext"… Originals are never overwritten.
    static func freeURL(in directory: URL, name: String, ext: String) -> URL {
        var url = directory.appendingPathComponent("\(name).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(name) \(n).\(ext)")
            n += 1
        }
        return url
    }

    // MARK: Images (ImageIO)

    /// `maxPixel` caps the longest side; images are never scaled up.
    static func image(_ source: URL, to destination: URL, as type: UTType, quality: Double, maxPixel: Int?) throws {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw Failure("Can't read this image") }
        let longest = max(width, height)
        // The thumbnail API decodes, resizes and applies the EXIF rotation in one step.
        // ponytail: first frame only, so animated GIFs come out still.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixel ?? longest, longest),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(input, 0, options as CFDictionary) else {
            throw Failure("Can't decode this image")
        }
        try write(image, to: destination, as: type, quality: quality)
    }

    static func write(_ image: CGImage, to destination: URL, as type: UTType, quality: Double) throws {
        guard let output = CGImageDestinationCreateWithURL(destination as CFURL, type.identifier as CFString, 1, nil) else {
            throw Failure("Can't write to \(destination.deletingLastPathComponent().path)")
        }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw Failure("Couldn't save \(destination.lastPathComponent)") }
    }

    // MARK: PDF (PDFKit)

    /// One image per page: "name-1.png", "name-2.png"… (just "name.png" for a single page).
    static func rasterize(_ source: URL, into directory: URL, name: String, format: Format, dpi: Double, quality: Double,
                          progress: @Sendable (Double) -> Void) throws -> [URL] {
        guard let type = format.imageType, let document = PDFDocument(url: source), document.pageCount > 0 else {
            throw Failure("Can't read this PDF")
        }
        guard !document.isLocked else { throw Failure("This PDF is password protected") }
        let scale = dpi / 72
        var outputs: [URL] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            // bounds(for:) ignores the page's rotation; draw(with:to:) applies it.
            let box = page.bounds(for: .cropBox)
            let sideways = page.rotation % 180 != 0
            let width = Int(((sideways ? box.height : box.width) * scale).rounded())
            let height = Int(((sideways ? box.width : box.height) * scale).rounded())
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw Failure("Page \(index + 1) is too large at \(Int(dpi)) DPI")
            }
            context.setFillColor(.white)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .cropBox, to: context)
            guard let image = context.makeImage() else { throw Failure("Couldn't render page \(index + 1)") }
            let destination = freeURL(in: directory, name: document.pageCount > 1 ? "\(name)-\(index + 1)" : name, ext: format.rawValue)
            try write(image, to: destination, as: type, quality: quality)
            outputs.append(destination)
            progress(Double(index + 1) / Double(document.pageCount))
        }
        return outputs
    }

    /// Joins PDFs and images, in order, into one PDF. Images become one page each.
    static func makePDF(from sources: [URL], to destination: URL) throws {
        let output = PDFDocument()
        var keepAlive: [PDFDocument] = []
        for source in sources {
            if source.pathExtension.lowercased() == "pdf" {
                guard let document = PDFDocument(url: source), !document.isLocked else {
                    throw Failure("Can't read \(source.lastPathComponent)")
                }
                keepAlive.append(document)
                for index in 0..<document.pageCount {
                    if let page = document.page(at: index)?.copy() as? PDFPage { output.insert(page, at: output.pageCount) }
                }
            } else {
                guard let image = NSImage(contentsOf: source), let page = PDFPage(image: image) else {
                    throw Failure("Can't read \(source.lastPathComponent)")
                }
                output.insert(page, at: output.pageCount)
            }
        }
        guard output.pageCount > 0, output.write(to: destination) else {
            throw Failure("Couldn't save \(destination.lastPathComponent)")
        }
    }

    // MARK: Video and audio (ffmpeg)

    /// Codecs are spelled out rather than left to ffmpeg's per-container defaults, which vary between builds.
    static func ffmpegArguments(input: String, output: String, format: Format) -> [String] {
        var arguments = ["-nostdin", "-n", "-v", "error", "-progress", "pipe:1", "-i", input]
        switch format {
        case .mp4, .mov:
            // H.264 needs even dimensions; faststart lets the file play before it has fully loaded.
            arguments += ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2",
                          "-c:a", "aac", "-movflags", "+faststart"]
        case .mkv:
            arguments += ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-c:a", "aac"]
        case .webm:
            arguments += ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-c:a", "libopus"]
        case .gif:
            // ponytail: fixed 12 fps and 480px wide keep GIFs small; expose both if anyone asks.
            arguments += ["-vf", "fps=12,scale='min(480,iw)':-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse", "-loop", "0"]
        case .mp3:
            arguments += ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case .m4a:
            arguments += ["-vn", "-c:a", "aac", "-b:a", "192k"]
        case .wav:
            arguments += ["-vn", "-c:a", "pcm_s16le"]
        case .flac:
            arguments += ["-vn", "-c:a", "flac"]
        case .ogg:
            // Homebrew's ffmpeg ships without libvorbis, so .ogg files carry Opus.
            arguments += ["-vn", "-c:a", "libopus", "-b:a", "160k"]
        default:
            break
        }
        return arguments + [output]
    }

    /// Seconds encoded so far, from a line of `ffmpeg -progress` output.
    static func progressSeconds(_ line: String) -> Double? {
        line.hasPrefix("out_time_us=") ? Double(line.dropFirst(12)).map { $0 / 1_000_000 } : nil
    }
}
