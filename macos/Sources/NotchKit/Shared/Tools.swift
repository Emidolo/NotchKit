import SwiftUI

/// External command-line tools (ffmpeg, cwebp, yt-dlp).
enum Tool {
    /// Homebrew on Apple Silicon, then on Intel.
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin"]

    static func find(_ name: String) -> URL? {
        searchPaths.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Apps launched from Finder get a bare PATH. Tools need Homebrew's on it to find each other
    /// (yt-dlp looks for ffmpeg and a JavaScript runtime there).
    static let environment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (searchPaths + [environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        return environment
    }()

    /// The line worth showing a person when a tool fails: its last line of stderr.
    static func lastError(_ result: ToolResult, fallback: String) -> String {
        result.error.components(separatedBy: "\n").last { !$0.isEmpty } ?? fallback
    }
}

struct ToolResult: Sendable {
    /// Exit status, or -1 if the tool could not be launched.
    let status: Int32
    let output: String
    let error: String
}

/// Runs a tool out of process. `onLine` receives each line of stdout as it arrives (for progress).
/// Cancelling the surrounding task terminates the tool.
func runTool(_ tool: URL, _ arguments: [String], onLine: (@MainActor @Sendable (String) -> Void)? = nil) async -> ToolResult {
    let process = Process()
    let output = Pipe(), error = Pipe()
    process.executableURL = tool
    process.arguments = arguments
    process.environment = Tool.environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = error
    // Not waitUntilExit(): it spins a run loop and deadlocks when several tools finish at once off the main thread.
    let exit = AsyncStream<Int32>.makeStream()
    process.terminationHandler = { process in
        exit.continuation.yield(process.terminationStatus)
        exit.continuation.finish()
    }
    do { try process.run() } catch let failure {
        return ToolResult(status: -1, output: "", error: failure.localizedDescription)
    }
    let errorHandle = error.fileHandleForReading
    return await withTaskCancellationHandler {
        // Drain stderr on its own thread so a noisy tool can't fill the pipe and stall.
        let errors = Task.detached { errorHandle.readDataToEndOfFile() }
        // Split by hand: `bytes.lines` drops empty lines, which would shift positional output.
        var lines: [String] = []
        var current = Data()
        do {
            for try await byte in output.fileHandleForReading.bytes {
                guard byte == 10 else { current.append(byte); continue }
                let line = String(decoding: current, as: UTF8.self)
                current.removeAll(keepingCapacity: true)
                lines.append(line)
                await onLine?(line)
            }
        } catch {}
        if !current.isEmpty { lines.append(String(decoding: current, as: UTF8.self)) }
        var status: Int32 = -1
        for await code in exit.stream { status = code }
        let errorText = String(decoding: await errors.value, as: UTF8.self)
        return ToolResult(status: status, output: lines.joined(separator: "\n"),
                          error: errorText.trimmingCharacters(in: .whitespacesAndNewlines))
    } onCancel: {
        process.terminate()
    }
}

/// Installs missing tools with Homebrew. Lives outside the views so an install survives the notch closing.
// ponytail: Homebrew only. Add a direct download into Application Support if someone without Homebrew needs it.
@MainActor @Observable
final class ToolInstaller {
    static let shared = ToolInstaller()

    private(set) var installing: Set<String> = []
    private(set) var errors: [String: String] = [:]
    /// Bumped after every install. Views that call `Tool.find` read this so they notice new tools.
    private(set) var revision = 0

    func install(_ package: String) {
        guard !installing.contains(package) else { return }
        guard let brew = Tool.find("brew") else {
            errors[package] = "Homebrew is needed first."
            NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
            return
        }
        installing.insert(package)
        errors[package] = nil
        Task {
            let result = await runTool(brew, ["install", package])
            if result.status != 0 { errors[package] = Tool.lastError(result, fallback: "brew install \(package) failed") }
            installing.remove(package)
            revision += 1
        }
    }
}

/// "Install <package>" with a spinner while Homebrew works and the error if it fails.
struct InstallButton: View {
    let package: String
    private let installer = ToolInstaller.shared

    var body: some View {
        if installer.installing.contains(package) {
            HStack(spacing: 6) {
                ProgressView()
                Text("Installing \(package)…").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 6) {
                Button(installer.errors[package] == nil ? "Install \(package)" : "Try Again") { installer.install(package) }
                    .help("Runs “brew install \(package)”.")
                if let error = installer.errors[package] {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(1).help(error)
                }
            }
        }
    }
}
