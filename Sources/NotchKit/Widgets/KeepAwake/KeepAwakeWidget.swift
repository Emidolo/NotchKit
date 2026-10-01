import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor extension Widget {
    static let keepAwake = Widget(id: "keepAwake", title: "Keep Awake", icon: "cup.and.saucer", indicator: {
        let keepAwake = KeepAwake.shared
        guard keepAwake.isActive || keepAwake.claude != nil else { return nil }
        return AnyView(HStack(spacing: 4) {
            if let claude = keepAwake.claude?.event {
                Image(systemName: claude.symbol).foregroundStyle(claude.color).accessibilityLabel(claude.label)
            }
            if let until = keepAwake.manualUntil, until != .distantFuture {
                Text(until, style: .timer).monospacedDigit().accessibilityLabel("Keep awake time left")
            } else if keepAwake.isActive {
                Image(systemName: "cup.and.saucer.fill").accessibilityLabel("Keeping awake")
            }
        }
        .font(.system(size: 10, weight: .medium)))
    }) {
        AnyView(KeepAwakeView())
    }
}

extension ClaudeEvent {
    var label: String {
        switch self {
        case .working: "Claude is working…"
        case .finished, .ended: "Claude finished"
        case .input: "Claude needs input"
        }
    }
    var symbol: String {
        switch self {
        case .working: "sparkles"
        case .finished, .ended: "checkmark.circle.fill"
        case .input: "exclamationmark.bubble.fill"
        }
    }
    var color: Color {
        switch self {
        case .working: .orange
        case .finished, .ended: .green
        case .input: .yellow
        }
    }
}

struct KeepAwakeView: View {
    @Bindable private var keepAwake = KeepAwake.shared
    @State private var customMinutes = ""

    var body: some View {
        HStack(spacing: 14) {
            Button {
                if keepAwake.manualUntil == nil { keepAwake.turnOn(minutes: nil) } else { keepAwake.turnOff() }
            } label: {
                Image(systemName: keepAwake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(.system(size: 24))
                    .frame(width: 60, height: 60)
                    .background(keepAwake.isActive ? Color.orange.opacity(0.85) : Color.white.opacity(0.1), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(keepAwake.manualUntil == nil ? "Keep awake until turned off" : "Stop keeping awake")
            .accessibilityLabel(keepAwake.manualUntil == nil ? "Keep awake" : "Stop keeping awake")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(keepAwake.isActive ? "Keeping awake" : "Sleep allowed").font(.headline)
                    if let until = keepAwake.manualUntil, until != .distantFuture {
                        Text(until, style: .timer).font(.headline.monospacedDigit()).foregroundStyle(.orange)
                    }
                }
                Text(detail).font(.caption).foregroundStyle(keepAwake.blocked == nil ? Color.secondary : Color.orange).lineLimit(1)
                    .help(keepAwake.reasons.joined(separator: "\n"))
                HStack(spacing: 4) {
                    ForEach([15, 30, 60, 120], id: \.self) { minutes in
                        Button(minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h") { keepAwake.turnOn(minutes: minutes) }
                            .help("Keep awake for \(minutes) minutes")
                    }
                    TextField("min", text: $customMinutes)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 44)
                        .onSubmit {
                            if let minutes = Int(customMinutes), (1...1440).contains(minutes) { keepAwake.turnOn(minutes: minutes) }
                            customMinutes = ""
                        }
                        .help("Custom duration in minutes, then Return")
                }
                if let claude = keepAwake.claude?.event {
                    Label(claude.label, systemImage: claude.symbol).font(.caption).foregroundStyle(claude.color)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 8) {
                Toggle("Allow display sleep", isOn: $keepAwake.rules.allowDisplaySleep)
                    .help("Keep the system awake but let the screen turn off.")
                Button("Rules…") { SettingsWindow.show(tab: "keepAwake") }
                    .help("Automatic rules, closed-lid mode, Claude Code and the session log")
            }
        }
        .controlSize(.small)
    }

    private var detail: String {
        if let blocked = keepAwake.blocked { return blocked }
        guard let first = keepAwake.reasons.first else { return "Turn on, or pick a duration." }
        return keepAwake.reasons.count > 1 ? "\(first) (+\(keepAwake.reasons.count - 1) more)" : first
    }
}

// MARK: - Rules

/// The Keep Awake tab of the Settings window.
struct KeepAwakeSettingsView: View {
    @Bindable private var keepAwake = KeepAwake.shared
    @State private var newProcess = ""
    @State private var hooksMessage: String?

    var body: some View {
        Form {
            Section("Keep awake automatically") {
                Toggle("While a download or conversion is running", isOn: $keepAwake.rules.whileBusy)
                Toggle("While on AC power", isOn: $keepAwake.rules.whileOnAC)
                Toggle("While an external display is connected", isOn: $keepAwake.rules.whileExternalDisplay)
                Toggle("While these apps are running", isOn: $keepAwake.rules.whileApps)
                if keepAwake.rules.whileApps {
                    ForEach($keepAwake.rules.apps) { $app in
                        row(Toggle(app.name, isOn: $app.enabled)) { keepAwake.rules.apps.removeAll { $0.id == app.id } }
                    }
                    Button("Add App…") { addApp() }
                }
                Toggle("While these processes are running", isOn: $keepAwake.rules.whileProcesses)
                if keepAwake.rules.whileProcesses {
                    ForEach($keepAwake.rules.processes) { $process in
                        row(Toggle(process.name, isOn: $process.enabled)) { keepAwake.rules.processes.removeAll { $0.id == process.id } }
                    }
                    TextField("Add a process name, then Return", text: $newProcess).onSubmit {
                        let name = newProcess.trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty, !keepAwake.rules.processes.contains(where: { $0.name == name }) {
                            keepAwake.rules.processes.append(.init(name: name))
                        }
                        newProcess = ""
                    }
                    Text("Matched against executable names, checked every 10 seconds.").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Claude Code") {
                Toggle("While Claude Code is working", isOn: $keepAwake.rules.whileClaude)
                Stepper("Stay awake \(keepAwake.rules.claudeGraceMinutes) min after it finishes", value: $keepAwake.rules.claudeGraceMinutes, in: 1...60)
                Toggle("Play a sound when Claude finishes or needs input", isOn: $keepAwake.rules.claudeSound)
                HStack {
                    Button("Install Hooks") { hooks("install") }
                    Button("Remove Hooks") { hooks("remove") }
                    Text(hooksMessage ?? "Adds hooks to ~/.claude/settings.json so Claude Code reports to the notch.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Battery and display") {
                Toggle("Stop keeping awake on battery below \(keepAwake.rules.batteryFloor)%", isOn: $keepAwake.rules.batteryFloorEnabled)
                if keepAwake.rules.batteryFloorEnabled {
                    Stepper("Battery level: \(keepAwake.rules.batteryFloor)%", value: $keepAwake.rules.batteryFloor, in: 5...90, step: 5)
                }
                Toggle("Allow display sleep while keeping the system awake", isOn: $keepAwake.rules.allowDisplaySleep)
            }

            Section("Closed lid") {
                Text("""
                    With the lid closed, macOS only stays awake when it is on power with an external display attached. \
                    To stay awake with the lid closed and nothing attached, NotchKit can switch system sleep off entirely \
                    while keep-awake is active.
                    """).font(.callout)
                Label("""
                    A closed MacBook cannot cool itself well. Never put it in a bag like this. NotchKit switches sleep back on \
                    when keep-awake ends, on battery below \(max(keepAwake.rules.batteryFloor, 10))%, when the Mac runs hot, and when it quits.
                    """, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                if keepAwake.closedLid.helperInstalled {
                    Toggle("Stay awake with the lid closed", isOn: Binding(get: { keepAwake.closedLid.enabled }, set: { keepAwake.closedLid.setEnabled($0) }))
                    Button("Remove Helper…") { Task { await keepAwake.closedLid.removeHelper() } }
                } else {
                    Button("Install Helper…") { Task { await keepAwake.closedLid.installHelper() } }
                    Text("Asks for your password once to add a rule to \(ClosedLid.rulePath) that lets NotchKit run “pmset -a disablesleep” and nothing else.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let note = keepAwake.closedLid.note { Text(note).font(.caption).foregroundStyle(.red) }
            }

            Section("Recent sessions") {
                if keepAwake.log.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
                ForEach(keepAwake.log.prefix(20)) { session in
                    HStack {
                        Text(session.start.formatted(date: .abbreviated, time: .shortened))
                        Text(Duration.seconds(session.end.timeIntervalSince(session.start)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow)))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(session.reason).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ toggle: some View, remove: @escaping () -> Void) -> some View {
        HStack {
            toggle
            Spacer()
            iconButton("minus.circle", "Remove", action: remove)
        }
        .padding(.leading, 16)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let bundleID = Bundle(url: url)?.bundleIdentifier,
              !keepAwake.rules.apps.contains(where: { $0.bundleID == bundleID }) else { return }
        keepAwake.rules.apps.append(.init(bundleID: bundleID, name: url.deletingPathExtension().lastPathComponent))
    }

    /// Runs the bundled Scripts/claude-hooks.py, the same script the README describes running by hand.
    private func hooks(_ action: String) {
        guard let script = Bundle.main.url(forResource: "claude-hooks", withExtension: "py") else { return hooksMessage = "The hook script is missing from the app." }
        Task {
            let result = await runTool(URL(fileURLWithPath: "/usr/bin/python3"), [script.path, action])
            hooksMessage = result.status == 0 ? result.output : Tool.lastError(result, fallback: "The script failed.")
        }
    }
}
