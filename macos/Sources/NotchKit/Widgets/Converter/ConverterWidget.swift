import AppKit
import SwiftUI

@MainActor extension Widget {
    static let converter = Widget(id: "converter", title: "Converter", icon: "arrow.triangle.2.circlepath", indicator: {
        ConverterModel.shared.progress.map { AnyView(ProgressRing(fraction: $0)) }
    }) {
        AnyView(ConverterView())
    }
}

@MainActor @Observable
final class ConvertItem: Identifiable {
    enum State {
        case waiting
        /// Fraction done, or nil when it can't be measured.
        case running(Double?)
        case done([URL])
        case failed(String)
    }

    let url: URL
    let kind: Kind
    var state = State.waiting

    init(url: URL, kind: Kind) {
        self.url = url
        self.kind = kind
    }

    var isDone: Bool { if case .done = state { true } else { false } }
}

@MainActor @Observable
final class ConverterModel {
    static let shared = ConverterModel()

    private(set) var items: [ConvertItem] = []
    var format = Format.png {
        // A new target format means finished files are worth converting again.
        didSet { if format != oldValue { for item in items where !isRunning { item.state = .waiting } } }
    }
    var quality = 0.85
    /// Longest side in pixels for image output; empty keeps the original size.
    var maxPixel = ""
    var dpi = 150.0
    /// nil saves next to each original.
    var outputDirectory = UserDefaults.standard.string(forKey: "converterOutputDirectory").map { URL(fileURLWithPath: $0) } {
        didSet { UserDefaults.standard.set(outputDirectory?.path, forKey: "converterOutputDirectory") }
    }
    private(set) var isRunning = false
    @ObservationIgnored private var task: Task<Void, Never>?

    var formats: [Format] { Conversion.commonFormats(items.map(\.kind)) }
    var hasPDF: Bool { items.contains { $0.kind == .pdf } }
    var canConvert: Bool { !formats.isEmpty && items.contains { !$0.isDone } }

    /// Fraction of the list converted so far; nil when nothing is running.
    var progress: Double? {
        guard isRunning, !items.isEmpty else { return nil }
        let done = items.reduce(0.0) { sum, item in
            switch item.state {
            case .done: sum + 1
            case .running(let fraction): sum + (fraction ?? 0)
            default: sum
            }
        }
        return done / Double(items.count)
    }

    /// A command-line tool this batch needs but that isn't installed, with the Homebrew package that provides it.
    var missingTool: (name: String, package: String)? {
        _ = ToolInstaller.shared.revision
        if format == .webp { return Tool.find("cwebp") == nil ? ("cwebp", "webp") : nil }
        let needsFFmpeg = items.contains { $0.kind == .video || $0.kind == .audio }
        return needsFFmpeg && Tool.find("ffmpeg") == nil ? ("ffmpeg", "ffmpeg") : nil
    }

    /// Unsupported files and folders are skipped.
    func add(_ urls: [URL]) {
        for url in urls where !items.contains(where: { $0.url == url }) {
            if let kind = Kind(url) { items.append(ConvertItem(url: url, kind: kind)) }
        }
        fixFormat()
    }

    func remove(_ item: ConvertItem) {
        items.removeAll { $0 === item }
        fixFormat()
    }

    func clear() {
        stop()
        items = []
    }

    private func fixFormat() {
        if let first = formats.first, !formats.contains(format) { format = first }
    }

    func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        if runModal(panel) { add(panel.urls) }
    }

    func pickOutputDirectory() {
        if let url = chooseFolder(startingAt: outputDirectory) { outputDirectory = url }
        NotchController.shared.expand()
    }

    // The notch closes when the cursor leaves for the dialog, so bring it back afterwards.
    private func runModal(_ panel: NSOpenPanel) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let ok = panel.runModal() == .OK
        NotchController.shared.expand()
        return ok
    }

    // MARK: Converting

    private struct Options {
        let format: Format
        let quality: Double
        let maxPixel: Int?
        let dpi: Double
        let directory: URL?
    }

    func convert() {
        let options = Options(format: format, quality: quality, maxPixel: Int(maxPixel).flatMap { $0 > 0 ? $0 : nil },
                              dpi: dpi, directory: outputDirectory)
        // A merged PDF always contains the whole list, even files that were already converted.
        let batch = format == .pdf ? items : items.filter { !$0.isDone }
        guard !isRunning, canConvert else { return }
        isRunning = true
        task = Task {
            if options.format == .pdf {
                await merge(batch, options)
            } else {
                // One at a time: ffmpeg already uses every core.
                for item in batch where !Task.isCancelled { await convert(item, options) }
            }
            isRunning = false
        }
    }

    func stop() { task?.cancel() }

    private func convert(_ item: ConvertItem, _ options: Options) async {
        item.state = .running(nil)
        let directory = options.directory ?? item.url.deletingLastPathComponent()
        let name = item.url.deletingPathExtension().lastPathComponent
        let source = item.url
        do {
            switch (item.kind, options.format) {
            case (.image, .webp):
                guard let cwebp = Tool.find("cwebp") else { throw Failure("cwebp is not installed") }
                // ImageIO reads everything (HEIC, RAW…) but can't write WebP, so hand cwebp a PNG.
                let png = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
                defer { try? FileManager.default.removeItem(at: png) }
                try await offMain { try Conversion.image(source, to: png, as: .png, quality: 1, maxPixel: options.maxPixel) }
                let destination = Conversion.freeURL(in: directory, name: name, ext: "webp")
                let result = await runTool(cwebp, ["-quiet", "-q", String(Int(options.quality * 100)), png.path, "-o", destination.path])
                guard result.status == 0 else { throw Failure(result.error.isEmpty ? "cwebp failed" : result.error) }
                item.state = .done([destination])
            case (.image, _):
                guard let type = options.format.imageType else { throw Failure("Unsupported format") }
                let destination = Conversion.freeURL(in: directory, name: name, ext: options.format.rawValue)
                try await offMain {
                    try Conversion.image(source, to: destination, as: type, quality: options.quality, maxPixel: options.maxPixel)
                }
                item.state = .done([destination])
            case (.pdf, _):
                let outputs = try await offMain {
                    try Conversion.rasterize(source, into: directory, name: name, format: options.format,
                                             dpi: options.dpi, quality: options.quality) { fraction in
                        Task { @MainActor in if case .running = item.state { item.state = .running(fraction) } }
                    }
                }
                item.state = .done(outputs)
            case (.video, _), (.audio, _):
                item.state = .done([try await ffmpeg(item, directory: directory, name: name, format: options.format)])
            }
        } catch {
            item.state = Task.isCancelled ? .waiting : .failed((error as? Failure)?.message ?? error.localizedDescription)
        }
    }

    private func ffmpeg(_ item: ConvertItem, directory: URL, name: String, format: Format) async throws -> URL {
        guard let ffmpeg = Tool.find("ffmpeg") else { throw Failure("ffmpeg is not installed") }
        var seconds = 0.0
        if let ffprobe = Tool.find("ffprobe") {
            let probe = await runTool(ffprobe, ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", item.url.path])
            seconds = Double(probe.output) ?? 0
        }
        let duration = seconds
        // Encode into a hidden file of our own, so a failed or cancelled run never leaves a half-written
        // result behind and cleaning up can never delete somebody else's file.
        let partial = directory.appendingPathComponent(".NotchKit-\(UUID().uuidString).\(format.rawValue)")
        let arguments = Conversion.ffmpegArguments(input: item.url.path, output: partial.path, format: format)
        let result = await runTool(ffmpeg, arguments) { line in
            if duration > 0, let done = Conversion.progressSeconds(line) { item.state = .running(min(done / duration, 1)) }
        }
        guard result.status == 0, !Task.isCancelled else {
            try? FileManager.default.removeItem(at: partial)
            throw Failure(Tool.lastError(result, fallback: "ffmpeg failed"))
        }
        // moveItem refuses to replace an existing file.
        let destination = Conversion.freeURL(in: directory, name: name, ext: format.rawValue)
        try FileManager.default.moveItem(at: partial, to: destination)
        return destination
    }

    private func merge(_ batch: [ConvertItem], _ options: Options) async {
        let first = batch[0].url
        let name = first.deletingPathExtension().lastPathComponent + (batch.count > 1 ? " merged" : "")
        let destination = Conversion.freeURL(in: options.directory ?? first.deletingLastPathComponent(), name: name, ext: "pdf")
        let sources = batch.map(\.url)
        for item in batch { item.state = .running(nil) }
        do {
            try await offMain { try Conversion.makePDF(from: sources, to: destination) }
            for item in batch { item.state = .done([destination]) }
        } catch {
            let message = (error as? Failure)?.message ?? error.localizedDescription
            for item in batch { item.state = .failed(message) }
        }
    }

    private func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: work).value
    }
}

// MARK: - View

struct ConverterView: View {
    @Bindable private var model = ConverterModel.shared

    var body: some View {
        if model.items.isEmpty {
            VStack(spacing: 6) {
                EmptyHint(icon: "square.and.arrow.down", title: "Drop files on the notch", detail: "Images, PDFs, video and audio")
                Button("Choose Files…") { model.pickFiles() }
            }
            .controlSize(.small)
        } else {
            HStack(alignment: .top, spacing: 14) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.items) { ItemRow(item: $0, model: model) }
                    }
                }
                options.frame(width: 230)
            }
            .controlSize(.small)
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.formats.isEmpty {
                Text("These files have no output format in common.").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Picker("Output format", selection: $model.format) {
                        ForEach(model.formats) { format in
                            Text(format == .pdf && model.items.count > 1 ? "One PDF" : format.rawValue.uppercased()).tag(format)
                        }
                    }
                    .labelsHidden()
                    if model.format.isImage {
                        if model.hasPDF {
                            Picker("Resolution", selection: $model.dpi) {
                                ForEach([72.0, 150, 300, 600], id: \.self) { Text("\(Int($0)) DPI").tag($0) }
                            }
                            .labelsHidden()
                        } else {
                            TextField("Max px", text: $model.maxPixel)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                                .help("Longest side in pixels. Leave empty to keep the original size.")
                        }
                    }
                }
                if let tool = model.missingTool {
                    HStack(spacing: 6) {
                        Text("Needs \(tool.name)").font(.caption).foregroundStyle(.orange)
                        InstallButton(package: tool.package)
                    }
                } else if model.format.hasQuality {
                    HStack(spacing: 4) {
                        Text("Quality").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $model.quality, in: 0.1...1).accessibilityLabel("Quality")
                        Text("\(Int(model.quality * 100))").font(.caption.monospacedDigit()).frame(width: 24, alignment: .trailing)
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                iconButton("plus", "Add files") { model.pickFiles() }
                Menu {
                    Button("Same Folder as Original") { model.outputDirectory = nil }
                    Button("Choose Folder…") { model.pickOutputDirectory() }
                } label: {
                    Image(systemName: "folder")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Save to: \(model.outputDirectory?.path ?? "same folder as the original")")
                .accessibilityLabel("Output folder")
                iconButton("trash", "Clear list") { model.clear() }
                Spacer()
                if model.isRunning {
                    Button("Stop") { model.stop() }
                } else {
                    Button("Convert") { model.convert() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canConvert || model.missingTool != nil)
                }
            }
        }
    }
}

private struct ItemRow: View {
    let item: ConvertItem
    let model: ConverterModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: item.kind.icon).frame(width: 16).foregroundStyle(.secondary)
            Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            switch item.state {
            case .waiting:
                remove
            case .running(let fraction):
                if let fraction {
                    ProgressView(value: fraction).frame(width: 70)
                } else {
                    ProgressView()
                }
            case .done(let outputs):
                iconButton("magnifyingglass", "Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).lineLimit(1).help(message)
                remove
            }
        }
        .font(.callout)
        .frame(height: 22)
    }

    private var remove: some View {
        iconButton("xmark", "Remove") { model.remove(item) }.disabled(model.isRunning)
    }
}
