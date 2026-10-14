import Foundation
import Testing
@testable import LustroCore

@Suite struct ProcessMonitorTests {
    @Test func enclosingAppIsTheOutermostBundle() {
        let gpu = "/Applications/Firefox.app/Contents/MacOS/gpu-helper.app/Contents/MacOS/Firefox GPU Helper"
        #expect(ProcessMonitor.enclosingApp(of: gpu) == "/Applications/Firefox.app")
        #expect(ProcessMonitor.enclosingApp(of: "/usr/libexec/fileproviderd") == nil)
        #expect(ProcessMonitor.enclosingApp(of: "/Users/me/Applications/Tool.app/Contents/MacOS/tool") == "/Users/me/Applications/Tool.app")
    }

    @Test func mainExecutableVersusHelper() {
        let app = "/Applications/Firefox.app"
        #expect(ProcessMonitor.isMainExecutable("/Applications/Firefox.app/Contents/MacOS/firefox", ofApp: app))
        #expect(!ProcessMonitor.isMainExecutable("/Applications/Firefox.app/Contents/MacOS/gpu-helper.app/Contents/MacOS/Firefox GPU Helper", ofApp: app))
        #expect(!ProcessMonitor.isMainExecutable("/Applications/Firefox.app/Contents/Library/LaunchServices/updater", ofApp: app))
    }

    @Test func systemPaths() {
        #expect(ProcessMonitor.isSystemPath("/System/Library/PrivateFrameworks/FileProvider.framework/Support/fileproviderd"))
        #expect(ProcessMonitor.isSystemPath("/usr/libexec/trustd"))
        #expect(!ProcessMonitor.isSystemPath("/Applications/Firefox.app/Contents/MacOS/firefox"))
        #expect(!ProcessMonitor.isSystemPath("/Users/me/.local/bin/claude"))
    }

    @Test func percentIsPerCore() {
        #expect(ProcessMonitor.percent(nanos: 2_000_000_000, over: 1) == 200)
        #expect(ProcessMonitor.percent(nanos: 500_000_000, over: 5) == 10)
        #expect(ProcessMonitor.percent(nanos: 1, over: 0) == 0)
    }

    @Test func liveSampleReadsOwnProcesses() {
        let monitor = ProcessMonitor()
        let samples = monitor.sample()
        #expect(!samples.isEmpty)
        // Lustro's own process (the test runner here) is left out.
        #expect(!samples.contains { $0.pid == getpid() })
        #expect(samples.count <= 24)
    }
}

@Suite struct ProcessQuitTests {
    @Test func quitsOnlyTheSameProcess() async throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { if sleeper.isRunning { sleeper.terminate() } }
        let pid = sleeper.processIdentifier
        let sample = try #require(ProcessMonitor().sample(limit: 10_000).first { $0.pid == pid })
        #expect(sample.isSystem)   // /bin/sleep lives in a system folder, so Lustro won't offer to quit it…
        #expect(!ProcessMonitor.send(SIGTERM, to: sample))

        // …but a user process with the same pid and start time is quit, and a reused pid is refused.
        func copy(isSystem: Bool, start: Date?) -> ProcessSample {
            ProcessSample(pid: pid, name: sample.name, path: sample.path, appPath: nil, appName: nil, isAppMain: false,
                          isSystem: isSystem, cpuPercent: 0, averageCPUPercent: 0, memory: 0, startDate: start)
        }
        #expect(!ProcessMonitor.send(SIGTERM, to: copy(isSystem: false, start: sample.startDate?.addingTimeInterval(-60))))
        #expect(ProcessMonitor.isRunning(sample))
        #expect(ProcessMonitor.send(SIGTERM, to: copy(isSystem: false, start: sample.startDate)))
        sleeper.waitUntilExit()
        #expect(!ProcessMonitor.isRunning(sample))
    }
}

@Suite struct SystemVitalsTests {
    @Test func cpuPercentFromTicks() {
        // user, system, idle, nice
        #expect(VitalsSampler.cpuPercent(previous: [100, 100, 800, 0], current: [200, 200, 1000, 0]) == 50)
        #expect(VitalsSampler.cpuPercent(previous: [0, 0, 0, 0], current: [0, 0, 0, 0]) == nil)
        // Counters wrap around.
        #expect(VitalsSampler.cpuPercent(previous: [UInt32.max, 0, 0, 0], current: [9, 0, 10, 0]) == 50)
    }

    @Test func liveSample() {
        let sampler = VitalsSampler()
        let first = sampler.sample()
        #expect(first.cpuPercent == nil)
        #expect(first.memoryTotal > 0)
        #expect(first.memoryUsed > 0 && first.memoryUsed <= first.memoryTotal)
        Thread.sleep(forTimeInterval: 0.3)
        #expect(sampler.sample().cpuPercent != nil)
    }
}

@Suite struct ProcessAdvisorTests {
    func sample(name: String = "Firefox GPU Helper",
                path: String = "/Applications/Firefox.app/Contents/MacOS/gpu-helper.app/Contents/MacOS/Firefox GPU Helper",
                cpu: Double, average: Double = 0, runningFor: TimeInterval = 60, system: Bool = false) -> ProcessSample {
        let app = ProcessMonitor.enclosingApp(of: path)
        return ProcessSample(pid: 42, name: name, path: path, appPath: app,
                             appName: app.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension },
                             isAppMain: app.map { ProcessMonitor.isMainExecutable(path, ofApp: $0) } ?? false, isSystem: system,
                             cpuPercent: cpu, averageCPUPercent: average, memory: 1 << 30, startDate: Date().addingTimeInterval(-runningFor))
    }

    @Test func runawayNeedsSustainedLoad() {
        let busy = sample(cpu: 650)
        var streaks: [Int32: Int] = [:]
        for _ in 0..<2 { streaks = ProcessAdvisor.updateStreaks(streaks, with: [busy]) }
        #expect(!ProcessAdvisor.isRunaway(busy, streak: streaks[42] ?? 0))
        streaks = ProcessAdvisor.updateStreaks(streaks, with: [busy])
        #expect(ProcessAdvisor.isRunaway(busy, streak: streaks[42] ?? 0))
        // One quiet sample resets the streak.
        streaks = ProcessAdvisor.updateStreaks(streaks, with: [sample(cpu: 20)])
        #expect(streaks[42] == nil)
    }

    @Test func longBusyProcessIsFlaggedImmediately() {
        let stuck = sample(cpu: 650, average: 600, runningFor: 39 * 3600)
        #expect(ProcessAdvisor.isRunaway(stuck, streak: 1))
        // Busy now but mostly idle over its life (e.g. a build that just started): wait for the streak.
        #expect(!ProcessAdvisor.isRunaway(sample(cpu: 650, average: 20, runningFor: 39 * 3600), streak: 1))
    }

    @Test func systemProcessesAreNeverRunaway() {
        #expect(!ProcessAdvisor.isRunaway(sample(cpu: 900, average: 900, runningFor: 99_999, system: true), streak: 10))
    }

    @Test func firefoxHelperAdvice() {
        let advice = ProcessAdvisor.advice(for: sample(cpu: 652, average: 600, runningFor: 39 * 3600))
        #expect(advice.headline == "Firefox GPU Helper is using \(6.5.formatted(.number.precision(.fractionLength(1)))) cores")   // decimal separator follows the locale
        #expect(advice.detail.hasPrefix("Running for 39 hours, busy most of that time."))
        #expect(advice.detail.contains("about:processes"))
        #expect(advice.quitEffect.contains("draws pages on screen"))
        #expect(advice.findURL == URL(string: "about:processes"))
    }

    @Test func mainAppAndCommandLineAdvice() {
        let app = ProcessAdvisor.advice(for: sample(name: "Code", path: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron", cpu: 180))
        #expect(app.headline == "Code is using \(1.8.formatted(.number.precision(.fractionLength(1)))) cores")
        #expect(app.quitEffect.contains("quits Visual Studio Code itself"))
        #expect(app.findURL == nil)
        let tool = ProcessAdvisor.advice(for: sample(name: "node", path: "/opt/homebrew/bin/node", cpu: 300))
        #expect(tool.detail.contains("command-line"))
    }
}

@Suite struct LaunchItemTests {
    @Test func parsesDisabledLabels() {
        let output = """
        	disabled services = {
        		"com.google.keystone.user.xpcservice" => enabled
        		"com.adobe.GC.AGM" => disabled
        		"com.old.style" => true
        		"com.docker.helper" => enabled
        	}
        """
        #expect(LaunchItemScanner.parseDisabled(output) == ["com.adobe.GC.AGM", "com.old.style"])
    }

    @Test func programFromPlist() {
        #expect(LaunchItemScanner.program(from: ["Program": "/opt/x"]) == "/opt/x")
        #expect(LaunchItemScanner.program(from: ["ProgramArguments": ["/Applications/A.app/Contents/MacOS/a", "--flag"]]) == "/Applications/A.app/Contents/MacOS/a")
        #expect(LaunchItemScanner.program(from: ["ProgramArguments": ["open", "-a", "X"]]) == nil)
    }

    @Test func bundleIDGuesses() {
        #expect(LaunchItemScanner.bundleIDGuesses(fromLabel: "com.docker.helper") == ["com.docker.helper", "com.docker"])
        #expect(LaunchItemScanner.bundleIDGuesses(fromLabel: "agent") == [])
    }

    @Test func scanFindsBrokenAndSkipsAppleAndHealthyDaemons() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lustro-launch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let system = root.appendingPathComponent("system")
        func write(_ folder: URL, _ label: String, program: String) throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: ["Label": label, "ProgramArguments": [program]], format: .xml, options: 0)
            try data.write(to: folder.appendingPathComponent("\(label).plist"))
        }
        let agents = home.appendingPathComponent("Library/LaunchAgents")
        try write(agents, "com.example.ok", program: "/bin/sh")
        try write(agents, "com.example.gone", program: "/Applications/Gone.app/Contents/MacOS/helper")
        try write(agents, "com.apple.something", program: "/bin/sh")
        try write(system.appendingPathComponent("Library/LaunchAgents"), "com.vendor.all", program: "/bin/sh")
        try write(system.appendingPathComponent("Library/LaunchDaemons"), "com.vendor.daemon", program: "/bin/sh")
        try write(system.appendingPathComponent("Library/LaunchDaemons"), "com.vendor.brokendaemon", program: "/nope/daemon")

        let items = LaunchItemScanner(home: home, systemRoot: system).scan(disabledLabels: ["com.vendor.all"])
        #expect(items.map(\.label) == ["com.example.ok", "com.vendor.all", "com.example.gone", "com.vendor.brokendaemon"])
        let gone = try #require(items.first { $0.label == "com.example.gone" })
        #expect(gone.isBroken && gone.canRemove && !gone.canToggle)
        #expect(gone.appPath == "/Applications/Gone.app")
        let daemon = try #require(items.first { $0.label == "com.vendor.brokendaemon" })
        #expect(!daemon.canRemove && !daemon.canToggle)
        #expect(items.first { $0.label == "com.vendor.all" }?.isDisabled == true)
    }
}

@Suite struct TuneUpTests {
    @Test func parsesSnapshots() {
        let output = """
        Snapshots for disk /:
        com.apple.TimeMachine.2026-10-14-101010.local
        com.apple.TimeMachine.2026-10-14-111010.local
        """
        #expect(LocalSnapshots.parse(output).count == 2)
        #expect(LocalSnapshots.parse("Snapshots for disk /:\n").isEmpty)
    }

    @Test func compactsAnSQLiteIndex() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lustro-mail-\(UUID().uuidString)/Library/Mail/V10/MailData")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        let index = folder.appendingPathComponent("Envelope Index")
        let create = Shell.run("/usr/bin/sqlite3", [index.path, "CREATE TABLE t(x); INSERT INTO t VALUES (randomblob(100000)); DELETE FROM t;"])
        #expect(create.status == 0)
        let home = folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        #expect(MailIndex.files(home: home).map { $0.resolvingSymlinksInPath().path } == [index.resolvingSymlinksInPath().path])
        let before = MailIndex.size(home: home)
        try MailIndex.compact(index)
        #expect(MailIndex.size(home: home) < before)
        // The safety copy is removed once the compacted index checks out.
        #expect(!FileManager.default.fileExists(atPath: index.path + ".lustro-backup"))
        #expect(Shell.run("/usr/bin/sqlite3", [index.path, "PRAGMA integrity_check;"]).output.trimmingCharacters(in: .whitespacesAndNewlines) == "ok")
    }
}
