import AppKit
import LustroCore
import Observation

/// Live system readings, launch agents and tune-ups for the Maintenance screen.
@MainActor @Observable
final class MaintenanceModel {
    enum SortKey: Hashable { case cpu, memory }
    enum TuneUp: Hashable { case snapshots, mail, dns, spotlight }
    enum TuneUpStatus: Equatable { case running, done(String), failed(String) }
    enum QuitPhase: Equatable { case confirm, waiting, stillRunning }

    private(set) var vitals: SystemVitals?
    private(set) var cpuHistory: [Double] = []
    private(set) var processes: [ProcessSample] = []
    private(set) var runaway: ProcessSample?
    var sort: SortKey = .cpu

    private(set) var launchItems: [LaunchItem] = []
    private(set) var launchNames: [String: String] = [:]
    private(set) var snapshots: [String] = []
    private(set) var purgeable: Int64 = 0
    private(set) var mailIndexSize: Int64?
    private(set) var tuneUps: [TuneUp: TuneUpStatus] = [:]

    var quitTarget: ProcessSample?
    private(set) var quitPhase: QuitPhase = .confirm

    /// Sample every 5 seconds while the screen is open, every minute otherwise (enough for the sidebar alert).
    var isVisible = false {
        didSet { if isVisible != oldValue { restartSampling() } }
    }

    private let sampler = VitalsSampler()
    private let monitor = ProcessMonitor { pid in
        NSRunningApplication(processIdentifier: pid)?.localizedName
    }
    private var streaks: [Int32: Int] = [:]
    private var loop: Task<Void, Never>?

    var visibleProcesses: [ProcessSample] {
        let sorted = sort == .cpu ? processes : processes.sorted { $0.memory > $1.memory }
        return Array(sorted.prefix(8))
    }

    // MARK: - Sampling

    func startSampling() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sampleNow()
                // The first two readings come quickly so CPU numbers appear without a long wait.
                let seconds: Double = self.isVisible ? (self.cpuHistory.count < 2 ? 1.5 : 5) : 60
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    private func restartSampling() {
        loop?.cancel()
        loop = nil
        startSampling()
    }

    func sampleNow() async {
        let sampler = sampler, monitor = monitor
        let (vitals, samples) = await Task.detached(priority: .utility) { (sampler.sample(), monitor.sample()) }.value
        self.vitals = vitals
        if let cpu = vitals.cpuPercent { cpuHistory = Array((cpuHistory + [cpu]).suffix(7)) }
        processes = samples
        streaks = ProcessAdvisor.updateStreaks(streaks, with: samples)
        runaway = samples.first { ProcessAdvisor.isRunaway($0, streak: streaks[$0.pid] ?? 0) }
    }

    // MARK: - Quitting processes

    func askToQuit(_ process: ProcessSample) {
        guard !process.isSystem else { return }
        quitPhase = .confirm
        quitTarget = process
    }

    /// Asks politely (or lets the app ask about unsaved work), then waits up to 10 seconds.
    func quit() async {
        guard let target = quitTarget else { return }
        quitPhase = .waiting
        if target.isAppMain, let app = NSRunningApplication(processIdentifier: target.pid) {
            app.terminate()
        } else {
            ProcessMonitor.send(SIGTERM, to: target)
        }
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(500))
            if !ProcessMonitor.isRunning(target) { return finishQuit() }
        }
        quitPhase = .stillRunning
    }

    func forceQuit() async {
        guard let target = quitTarget else { return }
        ProcessMonitor.send(SIGKILL, to: target)
        try? await Task.sleep(for: .milliseconds(500))
        finishQuit()
    }

    private func finishQuit() {
        quitTarget = nil
        quitPhase = .confirm
        streaks = [:]
        runaway = nil
        Task { await sampleNow() }
    }

    /// Opens a page that shows which tab is busy (Firefox's about:processes). Also copies the address,
    /// in case the browser doesn't accept it from outside.
    func findTab(for process: ProcessSample) {
        guard let url = ProcessAdvisor.advice(for: process).findURL, let appPath = process.appPath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: appPath), configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Launch agents

    func refreshLaunchItems() async {
        let items = await Task.detached(priority: .utility) {
            LaunchItemScanner().scan(disabledLabels: LaunchControl.disabledLabels())
        }.value
        launchItems = items
        for item in items where launchNames[item.id] == nil {
            launchNames[item.id] = Self.appName(for: item)
        }
    }

    func setEnabled(_ enabled: Bool, _ item: LaunchItem) async {
        if let index = launchItems.firstIndex(of: item) { launchItems[index].isDisabled = !enabled }
        _ = await Task.detached(priority: .userInitiated) { LaunchControl.setEnabled(enabled, item) }.value
        await refreshLaunchItems()
    }

    /// Moves a broken agent's plist to the Trash and records it in History, so it can be put back.
    func remove(_ item: LaunchItem, app: AppModel) async {
        guard item.canRemove else { return }
        await Task.detached { LaunchControl.stop(item) }.value
        let size = Int64((try? item.plist.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let report = await Remover(policy: app.settings.policy(), mode: .trash)
            .remove([ScanItem(url: item.plist, size: size, isDirectory: false, note: "Broken launch agent")])
        app.record(module: "Maintenance", report: report, rules: [:], quitApps: [])
        await refreshLaunchItems()
    }

    private static func appName(for item: LaunchItem) -> String? {
        if let appPath = item.appPath, FileManager.default.fileExists(atPath: appPath) {
            return FileManager.default.displayName(atPath: appPath).replacingOccurrences(of: ".app", with: "")
        }
        for id in item.candidateBundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            }
        }
        return nil
    }

    // MARK: - Tune-ups

    func refreshTuneUps() async {
        let (snapshots, purgeable, mail) = await Task.detached(priority: .utility) {
            (LocalSnapshots.list(), LocalSnapshots.purgeableBytes(), MailIndex.files().isEmpty ? nil : MailIndex.size())
        }.value
        self.snapshots = snapshots
        self.purgeable = purgeable
        self.mailIndexSize = mail
    }

    func run(_ tuneUp: TuneUp) async {
        guard tuneUps[tuneUp] != .running else { return }
        tuneUps[tuneUp] = .running
        let result: TuneUpStatus
        switch tuneUp {
        case .snapshots:
            let before = purgeable
            let outcome = await Task.detached { LocalSnapshots.thin() }.value
            await refreshTuneUps()
            result = outcome.ok
                ? .done(before > purgeable ? String(localized: "Freed \((before - purgeable).formattedBytes)") : String(localized: "Nothing to thin right now"))
                : .failed(outcome.output.trimmingCharacters(in: .whitespacesAndNewlines))
        case .mail:
            if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty {
                result = .failed(String(localized: "Quit Mail first"))
            } else {
                let files = MailIndex.files()
                if files.isEmpty {
                    result = .failed(String(localized: "Needs Full Disk Access"))
                } else {
                    let before = MailIndex.size()
                    let error = await Task.detached { () -> String? in
                        do throws(MailIndex.Failure) {
                            for file in files { try MailIndex.compact(file) }
                            return nil
                        } catch {
                            return error.description
                        }
                    }.value
                    await refreshTuneUps()
                    let saved = before - (mailIndexSize ?? before)
                    result = error.map { .failed($0) } ?? .done(saved > 0 ? String(localized: "Saved \(saved.formattedBytes)") : String(localized: "Already compact"))
                }
            }
        case .dns:
            result = await runAsAdmin(.flushDNS, done: String(localized: "DNS cache cleared"))
        case .spotlight:
            result = await runAsAdmin(.rebuildSpotlight, done: String(localized: "Reindexing in the background"))
        }
        tuneUps[tuneUp] = result
    }

    /// Uses the standard macOS password prompt. Cancelling it isn't an error.
    private func runAsAdmin(_ task: AdminTask, done: String) async -> TuneUpStatus {
        let script = "do shell script \"\(task.command)\" with administrator privileges"
        let result = await Task.detached { Shell.run("/usr/bin/osascript", ["-e", script]) }.value
        if result.status == 0 { return .done(done) }
        if result.output.contains("-128") { return .failed(String(localized: "Cancelled")) }
        return .failed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
