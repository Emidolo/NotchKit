import Foundation

/// External command-line tools (ffmpeg, cwebp, later yt-dlp).
enum Tool {
    /// Homebrew on Apple Silicon, then on Intel.
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin"]

    static func find(_ name: String) -> URL? {
        searchPaths.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
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
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = error
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
        process.waitUntilExit()
        let errorText = String(decoding: await errors.value, as: UTF8.self)
        return ToolResult(status: process.terminationStatus, output: lines.joined(separator: "\n"),
                          error: errorText.trimmingCharacters(in: .whitespacesAndNewlines))
    } onCancel: {
        process.terminate()
    }
}
