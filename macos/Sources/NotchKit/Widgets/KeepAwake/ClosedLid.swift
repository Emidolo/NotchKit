import Foundation
import Observation

/// Staying awake with the lid closed and nothing plugged in.
///
/// macOS only does that by itself in clamshell mode (power + external display). The one switch that
/// overrides it is `pmset disablesleep`, which needs root. Without a Developer ID there can be no signed
/// helper daemon, so the helper is a one-line sudoers rule that lets this user run exactly
/// `pmset -a disablesleep 0` and `pmset -a disablesleep 1` without a password, and nothing else.
///
/// Sleep is only ever disabled while the user has switched this on AND something is keeping the Mac
/// awake, and it is restored when keep-awake ends, on low battery, under thermal pressure, on quit,
/// and at the next launch after a crash.
@MainActor @Observable
final class ClosedLid {
    nonisolated static let rulePath = "/etc/sudoers.d/notchkit"

    /// What the user asked for. In force only while keep-awake is active.
    private(set) var enabled = false
    /// The last problem, or why it was switched off.
    private(set) var note: String?
    private(set) var helperInstalled = FileManager.default.fileExists(atPath: ClosedLid.rulePath)
    /// What pmset was last told.
    @ObservationIgnored private var applied = false

    // MARK: Helper

    /// The sudoers line, or nil for a user name that isn't safe to put in one.
    nonisolated static func rule(user: String) -> String? {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !user.isEmpty, user.unicodeScalars.allSatisfy(safe.contains), !user.hasPrefix("-") else { return nil }
        return "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
    }

    /// Shell that writes the rule into `directory`, refusing to install anything `visudo` rejects.
    /// The temporary name has a dot in it, which sudo ignores, so a half-written rule is never live.
    nonisolated static func installCommand(user: String, directory: String = "/etc/sudoers.d") -> String? {
        guard let rule = rule(user: user) else { return nil }
        let temp = "\(directory)/notchkit.tmp", final = "\(directory)/notchkit"
        return "printf '%s\\n' '\(rule)' > \(temp) && /usr/sbin/visudo -cf \(temp) >/dev/null && /bin/chmod 0440 \(temp) && /bin/mv -f \(temp) \(final)"
            + " || { /bin/rm -f \(temp); exit 1; }"
    }

    /// Runs `command` as root. macOS shows its own password dialog; the password never reaches this app.
    private func runAsAdmin(_ command: String) async -> String? {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let result = await runTool(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
        return result.status == 0 ? nil : Tool.lastError(result, fallback: "The change was not made.")
    }

    func installHelper() async {
        guard let command = ClosedLid.installCommand(user: NSUserName()) else { return note = "This account name can't be used in a sudoers rule." }
        note = await runAsAdmin(command)
        helperInstalled = FileManager.default.fileExists(atPath: ClosedLid.rulePath)
    }

    func removeHelper() async {
        // Give sleep back first, while we still can.
        enabled = false
        if applied { _ = await pmset(disableSleep: false) }
        applied = false
        note = await runAsAdmin("/bin/rm -f \(ClosedLid.rulePath)")
        helperInstalled = FileManager.default.fileExists(atPath: ClosedLid.rulePath)
    }

    // MARK: Switching

    func setEnabled(_ on: Bool) {
        enabled = on && helperInstalled
        note = nil
        KeepAwake.shared.evaluate()
    }

    /// Called on every keep-awake evaluation: applies the safety cutoffs, then brings pmset in line.
    func sync(keepAwakeActive: Bool, power: (onAC: Bool, battery: Int?), floor: Int) {
        if enabled {
            // A closed laptop can't shed heat, so these apply whatever the battery rule is set to.
            if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                enabled = false
                note = "Switched off: the Mac is running hot."
            } else if !power.onAC, let battery = power.battery, battery < max(floor, 10) {
                enabled = false
                note = "Switched off: battery below \(max(floor, 10))%."
            }
        }
        let wanted = enabled && keepAwakeActive
        guard wanted != applied else { return }
        applied = wanted
        Task {
            if let problem = await pmset(disableSleep: wanted) {
                note = problem
                enabled = false
                applied = false
            }
        }
    }

    private func pmset(disableSleep: Bool) async -> String? {
        let result = await runTool(URL(fileURLWithPath: "/usr/bin/sudo"), ["-n", "/usr/bin/pmset", "-a", "disablesleep", disableSleep ? "1" : "0"])
        return result.status == 0 ? nil : "Couldn't change the sleep setting: " + Tool.lastError(result, fallback: "sudo refused")
    }

    /// For quitting: blocks until sleep is allowed again.
    func revertNow() {
        guard applied else { return }
        applied = false
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"]
        try? process.run()
        process.waitUntilExit()
    }

    /// If a crash left sleep disabled, allow it again.
    func recoverAfterCrash() {
        guard helperInstalled else { return }
        Task {
            let settings = await runTool(URL(fileURLWithPath: "/usr/bin/pmset"), ["-g"]).output
            let disabled = settings.components(separatedBy: "\n").contains { $0.contains("SleepDisabled") && $0.hasSuffix("1") }
            if disabled && !applied { _ = await pmset(disableSleep: false) }
        }
    }
}
