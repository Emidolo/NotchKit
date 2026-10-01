import AppKit
import IOKit.ps
import IOKit.pwr_mgt
import Observation

/// What the user has asked to keep the Mac awake for. Stored as JSON in the defaults.
struct KeepAwakeRules: Codable, Equatable {
    struct App: Codable, Equatable, Identifiable {
        var bundleID: String
        var name: String
        var enabled = true
        var id: String { bundleID }
    }

    struct Process: Codable, Equatable, Identifiable {
        var name: String
        var enabled = true
        var id: String { name }
    }

    /// Let the screen sleep while the system stays awake.
    var allowDisplaySleep = false

    var whileApps = false
    var apps = [
        App(bundleID: "com.apple.dt.Xcode", name: "Xcode"),
        App(bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor"),
        App(bundleID: "com.microsoft.VSCode", name: "VS Code"),
        App(bundleID: "com.apple.Terminal", name: "Terminal"),
        App(bundleID: "com.googlecode.iterm2", name: "iTerm"),
        App(bundleID: "com.mitchellh.ghostty", name: "Ghostty"),
    ]

    var whileProcesses = false
    var processes = ["claude", "node", "npm", "python", "python3", "xcodebuild", "swift-build", "cargo", "make"].map { Process(name: $0) }

    /// A download or conversion in this app.
    var whileBusy = true
    var whileOnAC = false
    var whileExternalDisplay = false
    /// Driven by the Claude Code hooks (see Scripts/claude-hooks.py).
    var whileClaude = true
    /// Minutes to stay awake after Claude finishes or asks for input.
    var claudeGraceMinutes = 5
    var claudeSound = true

    /// On battery below this level, nothing keeps the Mac awake.
    var batteryFloorEnabled = true
    var batteryFloor = 20
}

/// The world as the rules see it.
struct KeepAwakeInputs {
    var manual = false
    var apps: Set<String> = []
    var processes: Set<String> = []
    var busy = false
    var onAC = true
    /// nil on a Mac without a battery.
    var battery: Int?
    var externalDisplay = false
    var claude = false
}

enum ClaudeEvent: String {
    case working, finished, input
    /// The session closed; clears the status.
    case ended

    /// `notchkit://claude?event=working|finished|input|ended`. Any app can open these, so anything else is refused.
    init?(url: URL) {
        guard url.scheme?.lowercased() == "notchkit", url.host?.lowercased() == "claude",
              let event = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "event" })?.value
        else { return nil }
        self.init(rawValue: event)
    }
}

extension KeepAwakeRules {
    /// Stored rules laid over the defaults, so rules saved by an older version (missing newer keys) still load.
    init(stored: Data?) {
        self.init()
        guard let stored, let saved = try? JSONSerialization.jsonObject(with: stored) as? [String: Any],
              let defaults = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: defaults.merging(saved) { $1 }),
              let rules = try? JSONDecoder().decode(KeepAwakeRules.self, from: merged) else { return }
        self = rules
    }

    /// Why the Mac should be awake right now (empty: let it sleep), or what overrode the reasons.
    func decide(_ inputs: KeepAwakeInputs) -> (reasons: [String], blocked: String?) {
        var reasons: [String] = []
        if inputs.manual { reasons.append("Turned on by you") }
        if whileApps { reasons += apps.filter { $0.enabled && inputs.apps.contains($0.bundleID) }.map { "\($0.name) is running" } }
        if whileProcesses { reasons += processes.filter { $0.enabled && inputs.processes.contains($0.name) }.map { "\($0.name) is running" } }
        if whileBusy && inputs.busy { reasons.append("A download or conversion is running") }
        if whileClaude && inputs.claude { reasons.append("Claude Code is working") }
        if whileOnAC && inputs.onAC { reasons.append("On AC power") }
        if whileExternalDisplay && inputs.externalDisplay { reasons.append("An external display is connected") }
        if batteryFloorEnabled, !inputs.onAC, let battery = inputs.battery, battery < batteryFloor, !reasons.isEmpty {
            return ([], "Battery below \(batteryFloor)%")
        }
        return (reasons, nil)
    }
}

/// Names of every running process, as `ps -c` would show them.
// ponytail: executable names only. A tool that runs inside another runtime (claude installed through npm
// shows up as "node") needs its argv read via KERN_PROCARGS2 to be told apart.
func runningProcessNames() -> Set<String> {
    var pids = [pid_t](repeating: 0, count: 8192)
    let count = proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.size * pids.count))
    var name = [CChar](repeating: 0, count: 256)
    var names = Set<String>()
    for pid in pids.prefix(Int(max(count, 0))) where pid > 0 && proc_name(pid, &name, UInt32(name.count)) > 0 {
        names.insert(String(cString: name))
    }
    return names
}

/// (on AC power, battery percent or nil without a battery)
func powerState() -> (onAC: Bool, battery: Int?) {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (true, nil) }
    let onAC = (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) != kIOPMBatteryPowerKey
    for source in sources {
        guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
              description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              let current = description[kIOPSCurrentCapacityKey] as? Int,
              let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
        return (onAC, current * 100 / max)
    }
    return (onAC, nil)
}

@MainActor @Observable
final class KeepAwake {
    static let shared = KeepAwake()

    struct Session: Codable, Identifiable {
        var start: Date
        var end: Date
        var reason: String
        var id: Date { start }
    }

    var rules: KeepAwakeRules {
        didSet {
            guard rules != oldValue else { return }
            UserDefaults.standard.set(try? JSONEncoder().encode(rules), forKey: "keepAwakeRules")
            watchProcesses()
            evaluate()
        }
    }
    /// When the manual session ends; `.distantFuture` means until turned off. nil: no manual session.
    private(set) var manualUntil: Date?
    /// Why the Mac is being kept awake. Empty: it isn't.
    private(set) var reasons: [String] = []
    /// What stopped keep-awake although something asked for it (low battery).
    private(set) var blocked: String?
    private(set) var claude: (event: ClaudeEvent, at: Date)?
    private(set) var log: [Session]
    let closedLid = ClosedLid()

    var isActive: Bool { !reasons.isEmpty }

    @ObservationIgnored private var assertion: IOPMAssertionID = 0
    @ObservationIgnored private var assertionType: String?
    @ObservationIgnored private var sessionStart: Date?
    @ObservationIgnored private var sessionReason = ""
    @ObservationIgnored private var manualTask: Task<Void, Never>?
    @ObservationIgnored private var claudeTask: Task<Void, Never>?
    @ObservationIgnored private var processTimer: Timer?
    @ObservationIgnored private var processes: Set<String> = []

    private init() {
        let defaults = UserDefaults.standard
        rules = KeepAwakeRules(stored: defaults.data(forKey: "keepAwakeRules"))
        log = defaults.data(forKey: "keepAwakeLog").flatMap { try? JSONDecoder().decode([Session].self, from: $0) } ?? []
    }

    /// Hooks up everything the rules react to. All of it is event driven except the process list,
    /// which has no notification and is only polled while a process rule is switched on.
    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { KeepAwake.shared.evaluate() } }
        }
        let center = NotificationCenter.default
        for name in [NSApplication.didChangeScreenParametersNotification, ProcessInfo.thermalStateDidChangeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { KeepAwake.shared.evaluate() } }
        }
        // Battery level and charger changes.
        let source = IOPSNotificationCreateRunLoopSource({ _ in
            Task { @MainActor in KeepAwake.shared.evaluate() }
        }, nil).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        watchBusy()
        watchProcesses()
        closedLid.recoverAfterCrash()
        evaluate()
    }

    // MARK: Manual sessions

    /// nil keeps awake until turned off.
    func turnOn(minutes: Int?) {
        manualTask?.cancel()
        manualUntil = minutes.map { Date().addingTimeInterval(Double($0) * 60) } ?? .distantFuture
        if let minutes {
            manualTask = Task {
                try? await Task.sleep(for: .seconds(minutes * 60))
                guard !Task.isCancelled else { return }
                turnOff()
            }
        }
        evaluate()
    }

    func turnOff() {
        manualTask?.cancel()
        manualUntil = nil
        evaluate()
    }

    // MARK: Claude Code

    func claudeEvent(_ event: ClaudeEvent) {
        claudeTask?.cancel()
        guard event != .ended else {
            claude = nil
            return evaluate()
        }
        claude = (event, Date())
        if rules.claudeSound, event != .working { NSSound(named: event == .finished ? "Glass" : "Funk")?.play() }
        claudeTask = Task {
            // "Working" with no follow-up means the session died; give up on it eventually.
            // ponytail: one status for all Claude sessions, latest event wins. Track session ids if that confuses.
            let limit = event == .working ? 2 * 3600 : rules.claudeGraceMinutes * 60
            try? await Task.sleep(for: .seconds(limit))
            guard !Task.isCancelled else { return }
            // "Needs input" stays on show until answered; the others have run their course.
            if event != .input { claude = nil }
            evaluate()
        }
        evaluate()
    }

    private var claudeKeepsAwake: Bool {
        guard let claude else { return false }
        return claude.event == .working || Date().timeIntervalSince(claude.at) < Double(rules.claudeGraceMinutes * 60)
    }

    // MARK: Evaluation

    func evaluate() {
        let power = powerState()
        let inputs = KeepAwakeInputs(
            manual: manualUntil != nil,
            apps: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)),
            processes: processes,
            busy: ConverterModel.shared.isRunning || YouTubeModel.shared.progress != nil,
            onAC: power.onAC, battery: power.battery,
            externalDisplay: NSScreen.screens.contains { screen in
                let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
                return CGDisplayIsBuiltin(id) == 0
            },
            claude: claudeKeepsAwake)
        let decision = rules.decide(inputs)
        // A manual session stopped by low battery stays stopped, rather than resuming when the charger returns.
        if decision.blocked != nil, manualUntil != nil {
            manualTask?.cancel()
            manualUntil = nil
        }
        let wasActive = isActive
        if reasons != decision.reasons { reasons = decision.reasons }
        if blocked != decision.blocked { blocked = decision.blocked }
        updateAssertion()
        if isActive && !wasActive {
            sessionStart = Date()
            sessionReason = reasons[0]
        } else if !isActive && wasActive, let start = sessionStart {
            log = Array(([Session(start: start, end: Date(), reason: sessionReason)] + log).prefix(100))
            UserDefaults.standard.set(try? JSONEncoder().encode(log), forKey: "keepAwakeLog")
            sessionStart = nil
        }
        closedLid.sync(keepAwakeActive: isActive, power: power, floor: rules.batteryFloor)
    }

    private func updateAssertion() {
        let wanted: String? = !isActive ? nil : rules.allowDisplaySleep ? kIOPMAssertPreventUserIdleSystemSleep : kIOPMAssertPreventUserIdleDisplaySleep
        guard wanted != assertionType else { return }
        if assertionType != nil { IOPMAssertionRelease(assertion) }
        assertionType = nil
        guard let wanted else { return }
        let result = IOPMAssertionCreateWithName(wanted as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "NotchKit Keep Awake" as CFString, &assertion)
        if result == kIOReturnSuccess { assertionType = wanted }
    }

    /// Re-evaluates when a conversion or download starts or ends.
    private func watchBusy() {
        withObservationTracking {
            _ = ConverterModel.shared.isRunning
            _ = YouTubeModel.shared.progress == nil
        } onChange: {
            Task { @MainActor in
                KeepAwake.shared.evaluate()
                KeepAwake.shared.watchBusy()
            }
        }
    }

    private func watchProcesses() {
        let needed = rules.whileProcesses && rules.processes.contains(where: \.enabled)
        guard needed != (processTimer != nil) else { return }
        processTimer?.invalidate()
        processTimer = nil
        processes = []
        guard needed else { return }
        let timer = Timer(timeInterval: 10, repeats: true) { _ in MainActor.assumeIsolated { KeepAwake.shared.pollProcesses() } }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        processTimer = timer
        pollProcesses()
    }

    private func pollProcesses() {
        let names = runningProcessNames()
        guard names != processes else { return }
        processes = names
        evaluate()
    }
}
