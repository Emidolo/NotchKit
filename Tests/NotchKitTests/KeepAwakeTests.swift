import Foundation
import Testing
@testable import NotchKit

@Test func nothingKeepsAwakeByDefault() {
    let decision = KeepAwakeRules().decide(KeepAwakeInputs(apps: ["com.apple.dt.Xcode"], processes: ["claude"], onAC: true, externalDisplay: true))
    #expect(decision.reasons.isEmpty && decision.blocked == nil)
}

@Test func eachRuleContributesItsReason() {
    var rules = KeepAwakeRules()
    rules.whileApps = true
    rules.whileProcesses = true
    rules.whileOnAC = true
    rules.whileExternalDisplay = true
    rules.apps[1].enabled = false   // Cursor
    let inputs = KeepAwakeInputs(manual: true, apps: ["com.apple.dt.Xcode", "com.todesktop.230313mzl4w4u92", "com.example.other"],
                                 processes: ["claude", "bash"], busy: true, onAC: true, battery: 80, externalDisplay: true, claude: true)
    #expect(rules.decide(inputs).reasons == [
        "Turned on by you", "Xcode is running", "claude is running", "A download or conversion is running",
        "Claude Code is working", "On AC power", "An external display is connected",
    ])
    rules.whileBusy = false
    rules.whileClaude = false
    #expect(!rules.decide(inputs).reasons.contains("Claude Code is working"))
    #expect(!rules.decide(inputs).reasons.contains("A download or conversion is running"))
}

@Test func lowBatteryOverridesEverythingButOnlyOnBattery() {
    let rules = KeepAwakeRules()   // floor 20%, enabled
    #expect(rules.decide(KeepAwakeInputs(manual: true, onAC: false, battery: 19)).blocked == "Battery below 20%")
    #expect(rules.decide(KeepAwakeInputs(manual: true, onAC: false, battery: 19)).reasons.isEmpty)
    #expect(rules.decide(KeepAwakeInputs(manual: true, onAC: false, battery: 20)).reasons == ["Turned on by you"])
    #expect(rules.decide(KeepAwakeInputs(manual: true, onAC: true, battery: 5)).reasons == ["Turned on by you"])
    #expect(rules.decide(KeepAwakeInputs(manual: true, onAC: false, battery: nil)).reasons == ["Turned on by you"])
    // Nothing asked for keep-awake: nothing to block.
    #expect(rules.decide(KeepAwakeInputs(onAC: false, battery: 5)).blocked == nil)
    var off = rules
    off.batteryFloorEnabled = false
    #expect(off.decide(KeepAwakeInputs(manual: true, onAC: false, battery: 5)).reasons == ["Turned on by you"])
}

@Test func rulesSurviveStorage() throws {
    var rules = KeepAwakeRules()
    rules.processes.append(.init(name: "bun"))
    rules.batteryFloor = 35
    #expect(try JSONDecoder().decode(KeepAwakeRules.self, from: JSONEncoder().encode(rules)) == rules)
}

@Test func rulesFromAnOlderVersionKeepWhatTheyHad() {
    let old = KeepAwakeRules(stored: Data(#"{"whileOnAC": true, "batteryFloor": 40, "somethingRemoved": 1}"#.utf8))
    #expect(old.whileOnAC && old.batteryFloor == 40)
    #expect(old.whileBusy && old.apps.count == 6)   // defaults for keys the old version didn't have
    #expect(KeepAwakeRules(stored: Data("garbage".utf8)) == KeepAwakeRules())
    #expect(KeepAwakeRules(stored: nil) == KeepAwakeRules())
}

@Test func claudeHookURLs() {
    func event(_ url: String) -> ClaudeEvent? { ClaudeEvent(url: URL(string: url)!) }
    #expect(event("notchkit://claude?event=working") == .working)
    #expect(event("notchkit://claude?event=finished") == .finished)
    #expect(event("notchkit://claude?event=input") == .input)
    #expect(event("notchkit://claude?event=ended") == .ended)
    #expect(event("notchkit://claude?event=explode") == nil)
    #expect(event("notchkit://claude") == nil)
    #expect(event("notchkit://other?event=working") == nil)
    #expect(event("https://claude?event=working") == nil)
    #expect(event("file:///tmp/claude?event=working") == nil)
}

// Only this user's processes are visible, which is all the rules need.
@Test func runningProcessesIncludeThisUsersApps() {
    let names = runningProcessNames()
    #expect(names.count > 20)
    #expect(names.contains("Finder"))
}

@Test func powerStateIsSane() {
    let power = powerState()
    if let battery = power.battery { #expect((0...100).contains(battery)) }
}

@Test func sudoersRuleOnlyForSafeUserNames() {
    #expect(ClosedLid.rule(user: "emiliano") == "emiliano ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1")
    for user in ["", "a b", "x' ; rm -rf /", "-n", "a,b", "a\nroot ALL=(ALL) ALL"] {
        #expect(ClosedLid.rule(user: user) == nil, "\(user)")
    }
}

/// Runs the real install command (minus the root part) into a scratch folder and checks sudo's own
/// validator accepted what was written.
@Test func helperInstallCommandWritesAValidatedRule() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NotchKitTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let command = try #require(ClosedLid.installCommand(user: "emiliano", directory: directory.path))
    let result = await runTool(URL(fileURLWithPath: "/bin/sh"), ["-c", command])
    #expect(result.status == 0, "\(result.error)")
    let installed = directory.appendingPathComponent("notchkit")
    #expect(try String(contentsOf: installed, encoding: .utf8) == ClosedLid.rule(user: "emiliano")! + "\n")
    #expect(try FileManager.default.attributesOfItem(atPath: installed.path)[.posixPermissions] as? Int == 0o440)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["notchkit"])
    #expect(ClosedLid.installCommand(user: "bad name") == nil)
}

/// Whether this process holds the assertion (the installed app may hold its own at the same time).
private func assertionHeld() async -> Bool {
    let mine = "pid \(ProcessInfo.processInfo.processIdentifier)("
    return await runTool(URL(fileURLWithPath: "/usr/bin/pmset"), ["-g", "assertions"]).output
        .components(separatedBy: "\n").contains { $0.contains(mine) && $0.contains("NotchKit Keep Awake") }
}

/// The real engine end to end: power assertion taken and released, session logged, and a running
/// conversion keeping the Mac awake by itself.
@MainActor @Test func engineHoldsAndReleasesTheAssertion() async throws {
    let keepAwake = KeepAwake.shared
    keepAwake.rules = KeepAwakeRules()
    keepAwake.rules.batteryFloorEnabled = false   // the machine running the tests may be on a low battery
    keepAwake.start()
    #expect(!keepAwake.isActive)
    #expect(await !assertionHeld())

    let sessions = keepAwake.log.count
    keepAwake.turnOn(minutes: 5)
    #expect(keepAwake.reasons == ["Turned on by you"])
    #expect(keepAwake.manualUntil.map { $0.timeIntervalSinceNow > 290 && $0.timeIntervalSinceNow <= 300 } == true)
    #expect(await assertionHeld())
    keepAwake.turnOff()
    #expect(!keepAwake.isActive)
    #expect(await !assertionHeld())
    #expect(keepAwake.log.count == sessions + 1)
    #expect(keepAwake.log.first?.reason == "Turned on by you")

    // Claude: awake while working and through the grace period, not after the session ends.
    keepAwake.rules.claudeSound = false
    keepAwake.claudeEvent(.working)
    #expect(keepAwake.reasons == ["Claude Code is working"])
    keepAwake.claudeEvent(.finished)
    #expect(keepAwake.isActive && keepAwake.claude?.event == .finished)
    keepAwake.claudeEvent(.ended)
    #expect(!keepAwake.isActive && keepAwake.claude == nil)

    // A conversion in the app.
    guard let ffmpeg = Tool.find("ffmpeg") else { return }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NotchKitTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let clip = directory.appendingPathComponent("clip.mov")
    let made = await runTool(ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "testsrc2=duration=6:size=1280x720:rate=30", clip.path])
    try #require(made.status == 0)
    let converter = ConverterModel.shared
    converter.clear()
    converter.add([clip])
    converter.format = .webm
    converter.convert()
    try await Task.sleep(for: .milliseconds(300))
    #expect(converter.isRunning)
    #expect(keepAwake.reasons == ["A download or conversion is running"])
    #expect(await assertionHeld())
    converter.stop()
    for _ in 0..<50 where converter.isRunning { try await Task.sleep(for: .milliseconds(100)) }
    try await Task.sleep(for: .milliseconds(200))
    #expect(!keepAwake.isActive)
    #expect(await !assertionHeld())
    converter.clear()
}
