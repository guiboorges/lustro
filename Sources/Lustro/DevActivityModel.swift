import AppKit
import LustroCore
import Observation

/// AI agents, terminal commands, orphans, ports and containers for the Dev Activity screen.
@MainActor @Observable
final class DevActivityModel {
    enum Filter: Hashable { case all, ai, terminals }
    enum StopPhase: Equatable { case confirm, waiting, stillRunning }

    private(set) var report = DevActivityReport.empty
    private(set) var runtime: ContainerRuntime?
    private(set) var containers: [ContainerStat] = []
    /// Seconds since the last keystroke, per terminal.
    private(set) var idle: [String: TimeInterval] = [:]
    var filter: Filter = .all

    var stopTarget: ProcessGroup?
    private(set) var stopPhase: StopPhase = .confirm

    /// Every 5 seconds while the screen is open, every minute otherwise (enough for the sidebar's orphan count).
    var isVisible = false {
        didSet { if isVisible != oldValue { restartSampling() } }
    }

    private let table = ProcessTable()
    private var launchPrograms: Set<String>?
    private var lastContainerCheck = Date.distantPast
    private var lastPortScan = Date.distantPast
    private var ports: [ListeningPort] = []
    private var loop: Task<Void, Never>?

    /// Orphans first, then agents, terminal commands and what apps started.
    var visibleGroups: [ProcessGroup] {
        let all = report.orphans + report.sessions
        switch filter {
        case .all: return all
        case .ai: return all.filter(\.isAgent)
        case .terminals: return all.filter { !$0.isAgent }
        }
    }

    // MARK: - Sampling

    func startSampling() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sampleNow()
                try? await Task.sleep(for: .seconds(self.isVisible ? 5 : 60))
            }
        }
    }

    private func restartSampling() {
        loop?.cancel()
        loop = nil
        startSampling()
    }

    func sampleNow() async {
        let table = table
        let known = launchPrograms
        // Ports change rarely; reading every process's sockets every 15 seconds is enough.
        let scanPorts = Date().timeIntervalSince(lastPortScan) >= 14
        let (processes, scanned, programs) = await Task.detached(priority: .utility) {
            let programs = known ?? Set(LaunchItemScanner().scan(disabledLabels: []).compactMap(\.program))
            let (processes, ports) = table.sample(includePorts: scanPorts)
            return (processes, ports, programs)
        }.value
        launchPrograms = programs
        if scanPorts {
            ports = scanned
            lastPortScan = Date()
        }
        let alive = Set(processes.map(\.pid))
        let ports = ports.filter { alive.contains($0.pid) }
        report = DevActivity.analyze(processes: processes, ports: ports, launchPrograms: programs)
        runtime = Containers.runtime(in: processes)
        var idle: [String: TimeInterval] = [:]
        for tty in Set(report.sessions.compactMap(\.root.tty)) { idle[tty] = ProcessTable.idleTime(tty: tty) }
        self.idle = idle

        if runtime == nil {
            containers = []
        } else if isVisible, Date().timeIntervalSince(lastContainerCheck) > 15, let cli = Containers.dockerCLI() {
            lastContainerCheck = Date()
            containers = await Task.detached(priority: .utility) { Containers.stats(cli: cli) }.value
        }
    }

    /// Launch agents can change while Lustro is open; re-read them on the next sample.
    func refresh() async {
        launchPrograms = nil
        lastContainerCheck = .distantPast
        lastPortScan = .distantPast
        await sampleNow()
    }

    // MARK: - Stopping a group

    func askToStop(_ group: ProcessGroup) {
        stopPhase = .confirm
        stopTarget = group
    }

    /// Asks every process in the group to stop, then waits up to 10 seconds.
    func stop() async {
        guard let group = stopTarget else { return }
        stopPhase = .waiting
        ProcessTable.signal(SIGTERM, group.members)
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(500))
            if !group.members.contains(where: ProcessTable.isRunning) { return finishStop() }
        }
        stopPhase = .stillRunning
    }

    func forceStop() async {
        guard let group = stopTarget else { return }
        ProcessTable.signal(SIGKILL, group.members.filter(ProcessTable.isRunning))
        try? await Task.sleep(for: .milliseconds(500))
        finishStop()
    }

    private func finishStop() {
        stopTarget = nil
        stopPhase = .confirm
        Task { await sampleNow() }
    }

    // MARK: - Actions

    func showFolder(_ group: ProcessGroup) {
        guard let folder = group.folder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
    }

    func openRuntime() {
        guard let app = runtime?.appPath else { return }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app), configuration: NSWorkspace.OpenConfiguration())
    }

    /// A plain-text summary for an issue, a chat or a colleague. Command lines are already redacted.
    func copyReport() {
        var lines = ["Dev Activity · \(Date().formatted(date: .abbreviated, time: .shortened))", ""]
        if !report.orphans.isEmpty {
            lines.append("Orphans (their terminal or session has ended)")
            for group in report.orphans { lines.append("- " + summary(group)) }
            lines.append("")
        }
        if !report.sessions.isEmpty {
            lines.append("Agents, terminals and app-started tools")
            for group in report.sessions {
                lines.append("- " + summary(group))
                for child in group.notableChildren.prefix(5) {
                    lines.append("    · \(DevActivity.displayCommand(child)) (\(Int(child.cpuPercent.rounded()))% CPU, \(child.memory.formattedBytes))")
                }
            }
            lines.append("")
        }
        if !report.ports.isEmpty {
            lines.append("Listening ports")
            for row in report.ports {
                lines.append("- \(row.port.port) \(row.port.exposed ? "(open to the network)" : "(this Mac only)") \(DevActivity.displayCommand(row.process))")
            }
            lines.append("")
        }
        if let runtime {
            lines.append("Containers: \(runtime.name) · \(Int(runtime.cpuPercent.rounded()))% CPU · \(runtime.memory.formattedBytes)")
            for container in containers { lines.append("- \(container.name): \(container.cpuPercent)% CPU, \(container.memory)") }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private func summary(_ group: ProcessGroup) -> String {
        var parts = [group.title]
        if let folder = group.folder { parts.append(folder.abbreviatingHome) }
        if let tty = group.root.tty { parts.append(tty) }
        if let running = group.root.runningTime { parts.append(ProcessAdvisor.formatHours(running)) }
        parts.append("\(Int(group.cpuPercent.rounded()))% CPU")
        parts.append(group.memory.formattedBytes)
        if !group.ports.isEmpty { parts.append("ports " + group.ports.map { String($0.port) }.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}
