import AppKit
import LustroCore
import SwiftUI

/// What you left running: AI agents, terminal commands, orphans, servers and containers.
struct DevActivityView: View {
    @Bindable var model: DevActivityModel
    @State private var copied = false

    var body: some View {
        VStack(spacing: 16) {
            PanelHeader(title: "Dev Activity",
                        subtitle: "What you left running: AI agents, terminals, servers and containers, grouped by where they started.") {
                Button(copied ? "Copied" : "Copy Report") {
                    model.copyReport()
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                }
                .buttonStyle(OutlineButtonStyle())
                .help("Copies a text summary. Command lines are redacted.")
                Button("Refresh") { Task { await model.refresh() } }.buttonStyle(InkButtonStyle())
            }
            if let orphan = model.report.orphans.first {
                OrphanBanner(group: orphan, others: model.report.orphans.count - 1,
                             showFolder: { model.showFolder(orphan) }, stop: { model.askToStop(orphan) })
            }
            HStack(alignment: .top, spacing: 16) {
                GroupsCard(model: model)
                PortsCard(model: model).frame(width: 392)
            }
            .frame(maxHeight: .infinity)
            if let runtime = model.runtime {
                ContainersCard(runtime: runtime, containers: model.containers, open: model.openRuntime)
            }
            Label("Command lines are shown with tokens and passwords hidden, and never leave this Mac.", systemImage: "info.circle")
                .font(.lCaption).foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { model.isVisible = true }
        .onDisappear { model.isVisible = false }
        .sheet(item: $model.stopTarget) { group in
            StopGroupSheet(model: model, group: group)
        }
    }
}

// MARK: - Describing groups

extension ProcessGroup {
    var symbol: String {
        switch kind {
        case .agent: "brain.head.profile"
        case .terminal: "terminal"
        case .orphan: "exclamationmark.triangle"
        case .launchedBy: "shippingbox"
        }
    }

    /// "Projects/REA" for a project folder, the full path otherwise.
    var shortFolder: String? {
        guard let folder else { return nil }
        let path = folder.abbreviatingHome
        let parts = path.split(separator: "/")
        if path.hasPrefix("/private/var/folders") || path.hasPrefix("/private/tmp") || path.hasPrefix("/tmp") {
            return "temporary folder"
        }
        return parts.count > 2 ? parts.suffix(2).joined(separator: "/") : path
    }

    var whereStarted: String {
        switch kind {
        case .agent, .terminal: root.tty.map { "Terminal \($0)" } ?? startedBy.map { "in \($0)" } ?? "no terminal"
        case .orphan: "parent gone"
        case .launchedBy(let app): "started by \(app)"
        }
    }

    func subtitle() -> String {
        var parts: [String] = []
        if let folder = shortFolder { parts.append(folder) }
        parts.append(whereStarted)
        if let running = root.runningTime { parts.append(ProcessAdvisor.formatHours(running)) }
        return parts.joined(separator: " · ")
    }

    /// What a child process is doing inside its group.
    func role(of child: ProcessEntry) -> String {
        if let port = ports.first(where: { $0.pid == child.pid }) { return "Server · port \(port.port)" }
        if DevActivity.agentName(child) != nil { return "Sub-agent" }
        let command = DevActivity.displayCommand(child).lowercased()
        if command.contains("mcp") { return "MCP server" }
        if isAgent, child.ppid == root.pid, child.arguments.contains("-c") {
            return "Tool command" + (child.runningTime.map { " · " + ProcessAdvisor.formatHours($0) } ?? "")
        }
        return child.runningTime.map(ProcessAdvisor.formatHours) ?? ""
    }
}

// MARK: - Orphan banner

private struct OrphanBanner: View {
    let group: ProcessGroup
    let others: Int
    let showFolder: () -> Void
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Tile(symbol: "exclamationmark.triangle", background: Theme.orange500, foreground: Theme.onBrand, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(group.title) has been running on its own for \(ProcessAdvisor.formatHours(group.root.runningTime ?? 0))")
                    .font(.lBodyStrong).foregroundStyle(Theme.onBrand).lineLimit(1)
                Text(detail).font(.lCaption).foregroundStyle(Theme.onBrandMuted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if group.folder != nil {
                Button("Show Folder", action: showFolder).buttonStyle(.plain).font(.lCalloutStrong).foregroundStyle(Theme.orange300)
            }
            Button("Stop It", action: stop).buttonStyle(BrandButtonStyle())
        }
        .padding(.leading, 14).padding(.trailing, 16).padding(.vertical, 14)
        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var detail: String {
        var text = "The terminal or agent session that started it has ended, but it kept going."
        if let port = group.ports.first(where: \.exposed) ?? group.ports.first {
            text += " It listens on port \(port.port)" + (port.exposed ? ", open to your whole network." : ", on this Mac only.")
        }
        if group.shortFolder == "temporary folder" { text += " Its folder is temporary." }
        if others > 0 { text += " \(others) more orphan\(others == 1 ? "" : "s") below." }
        return text
    }
}

// MARK: - Agents & terminals

private struct GroupsCard: View {
    let model: DevActivityModel

    var body: some View {
        @Bindable var model = model
        let agents = model.report.sessions.filter(\.isAgent).count
        let others = model.report.sessions.count - agents
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agents & terminals").font(.lTitle3)
                    Text("\(agents) AI session\(agents == 1 ? "" : "s") · \(others) command\(others == 1 ? "" : "s") · totals include child processes")
                        .font(.lCaption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer()
                Segmented(options: [(DevActivityModel.Filter.all, "All"), (.ai, "AI"), (.terminals, "Terminals")],
                          selection: $model.filter, ink: true)
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
            if model.visibleGroups.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle").font(.system(size: 22)).foregroundStyle(Theme.safe)
                    Text("Nothing running from a terminal or agent").font(.lCaption).foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.visibleGroups) { group in
                            GroupBlock(group: group, idle: group.root.tty.flatMap { model.idle[$0] }) { model.askToStop(group) }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .lustroCard()
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct GroupBlock: View {
    let group: ProcessGroup
    let idle: TimeInterval?
    let stop: () -> Void

    var body: some View {
        let children = group.notableChildren
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                let orphan = group.kind == .orphan
                Tile(symbol: group.symbol, background: orphan ? Theme.caution.opacity(0.12) : Theme.peach100,
                     foreground: orphan ? Theme.caution : Theme.rust700, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(group.title).font(.lCalloutStrong).lineLimit(1).truncationMode(.middle)
                        status
                    }
                    Text(group.subtitle()).font(.lCaption).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(cpuText(group.cpuPercent))%").font(.lCalloutStrong).monospacedDigit()
                    Text(group.memory.formattedBytes).font(.lCaption).foregroundStyle(Theme.textSecondary).monospacedDigit()
                }
                .fixedSize()
                Button("Stop", action: stop).buttonStyle(PillButtonStyle(tint: group.kind == .orphan ? Theme.caution : Theme.textPrimary))
            }
            .padding(.leading, 20).padding(.trailing, 16).padding(.vertical, 12)
            ForEach(children.prefix(3)) { child in
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textTertiary)
                    Text(DevActivity.displayCommand(child)).font(.lCaption).lineLimit(1).truncationMode(.tail)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .layoutPriority(1)
                    Text(group.role(of: child)).font(.lCaption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(cpuText(child.cpuPercent))%").font(.lCaption).monospacedDigit().frame(width: 40, alignment: .trailing)
                    Text(child.memory.formattedBytes).font(.lCaption).foregroundStyle(Theme.textSecondary).monospacedDigit()
                        .frame(width: 62, alignment: .trailing)
                }
                .padding(.leading, 68).padding(.trailing, 76).padding(.vertical, 8)
                .background(Theme.sunken)
                .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
                .help(DevActivity.displayCommand(child))
            }
            if children.count > 3 {
                Text("+ \(children.count - 3) more process\(children.count - 3 == 1 ? "" : "es")")
                    .font(.lCaption).foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 68).padding(.vertical, 6)
                    .background(Theme.sunken)
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        .help(group.folder ?? group.root.path)
    }

    @ViewBuilder private var status: some View {
        switch group.kind {
        case .orphan:
            Chip(text: "Orphan", tone: .caution).fixedSize()
        case .agent:
            if group.isWorking {
                Chip(text: "Working", tone: .safe).fixedSize()
            } else if let idle, idle >= 300 {
                Chip(text: "Idle \(Self.shortDuration(idle))", tone: .neutral).fixedSize()
                    .help("Nothing typed in this terminal for \(Self.shortDuration(idle))")
            }
        case .terminal, .launchedBy:
            EmptyView()
        }
    }

    /// "4 h", "1 day", "12 min".
    static func shortDuration(_ seconds: TimeInterval) -> String {
        if seconds >= 86_400 { let days = Int(seconds / 86_400); return "\(days) day\(days == 1 ? "" : "s")" }
        if seconds >= 3600 { return "\(Int(seconds / 3600)) h" }
        return "\(Int(seconds / 60)) min"
    }
}

private func cpuText(_ value: Double) -> String {
    value < 0.05 ? "0" : value < 1 ? String(format: "%.1f", value) : "\(Int(value.rounded()))"
}

// MARK: - Servers & ports

private struct PortsCard: View {
    let model: DevActivityModel

    var body: some View {
        let ports = model.report.ports
        let exposed = ports.filter(\.port.exposed).count
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Servers & ports").font(.lTitle3)
                Text("\(ports.count) listening" + (exposed > 0 ? " · \(exposed) open to your network" : ""))
                    .font(.lCaption).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
            if ports.isEmpty {
                Text("Nothing of yours is listening for connections.").font(.lCaption).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(ports) { row in portRow(row) }
                    }
                }
                .scrollIndicators(.hidden)
            }
            Label("Network ports can be reached by other devices on your Wi-Fi.", systemImage: "info.circle")
                .font(.lCaption).foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 14)
                .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .lustroCard()
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func portRow(_ row: PortRow) -> some View {
        let exposed = row.port.exposed
        let orphan = row.group?.kind == .orphan
        return HStack(spacing: 12) {
            Text(String(row.port.port)).font(.lCalloutStrong).monospacedDigit()
                .foregroundStyle(exposed ? Theme.caution : Theme.textPrimary)
                .frame(width: 62).padding(.vertical, 6)
                .background(exposed ? Theme.caution.opacity(0.12) : Theme.sunken, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(DevActivity.displayCommand(row.process)).font(.lCalloutStrong).lineLimit(1).truncationMode(.tail)
                Text(context(row)).font(.lCaption).foregroundStyle(orphan ? Theme.caution : Theme.textSecondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Chip(text: exposed ? "Network" : "Local", tone: exposed ? .caution : .neutral).fixedSize()
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        .help(DevActivity.displayCommand(row.process))
    }

    private func context(_ row: PortRow) -> String {
        guard let group = row.group else {
            return row.process.appPath.map(ProcessMonitor.displayName(ofApp:)) ?? row.process.cwd?.abbreviatingHome ?? ""
        }
        var parts: [String]
        switch group.kind {
        case .orphan: parts = ["Orphan"]
        case .agent(let name): parts = [name]
        case .terminal: parts = [group.title]
        case .launchedBy(let app): parts = ["Started by \(app)"]
        }
        if let folder = group.shortFolder { parts.append(folder) }
        if let running = row.process.runningTime { parts.append(ProcessAdvisor.formatHours(running)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Containers

private struct ContainersCard: View {
    let runtime: ContainerRuntime
    let containers: [ContainerStat]
    let open: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Tile(symbol: "shippingbox", size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(runtime.name) VM").font(.lCalloutStrong)
                Text("\(cpuText(runtime.cpuPercent))% CPU · \(runtime.memory.formattedBytes)"
                     + (runtime.startDate.map { " · running \(ProcessAdvisor.formatHours(Date().timeIntervalSince($0)))" } ?? ""))
                    .font(.lCaption).foregroundStyle(Theme.textSecondary)
            }
            .fixedSize()
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    if containers.isEmpty {
                        Text("No containers running, or the Docker CLI isn't installed.").font(.lCaption).foregroundStyle(Theme.textTertiary)
                    }
                    ForEach(containers) { container in
                        HStack(spacing: 8) {
                            Circle().fill(Theme.safe).frame(width: 6, height: 6)
                            Text(container.name).font(.lCaption)
                            Text(String(format: "%.1f%%", container.cpuPercent)).font(.lCaption).foregroundStyle(Theme.textSecondary).monospacedDigit()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .help("\(container.name) · \(container.memory)")
                    }
                }
            }
            .scrollIndicators(.hidden)
            if runtime.appPath != nil {
                Button("Open \(runtime.name)", action: open).buttonStyle(PillButtonStyle(tint: Theme.textPrimary))
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .lustroCard()
    }
}

// MARK: - Stop sheet

struct StopGroupSheet: View {
    let model: DevActivityModel
    let group: ProcessGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Tile(symbol: group.symbol, background: Theme.caution.opacity(0.12), foreground: Theme.caution, size: 52)
            Text("Stop \(group.title)?").font(.lTitle2).lineLimit(2)
            Text(explanation).font(.lCallout).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                row("Processes", "\(group.members.count)", first: true)
                row("Using", "\(cpuText(group.cpuPercent))% CPU · \(group.memory.formattedBytes)")
                if let folder = group.folder { row("Folder", folder.abbreviatingHome) }
                if !group.ports.isEmpty {
                    row("Ports", group.ports.map { "\($0.port)\($0.exposed ? " (network)" : "")" }.joined(separator: ", "))
                }
                if let running = group.root.runningTime { row("Running for", ProcessAdvisor.formatHours(running)) }
            }
            .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            note
            HStack(spacing: 10) {
                Button("Cancel") { model.stopTarget = nil }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                if group.folder != nil {
                    Button("Show Folder") { model.showFolder(group) }.buttonStyle(OutlineButtonStyle())
                }
                if model.stopPhase == .stillRunning {
                    Button("Force Stop") { Task { await model.forceStop() } }.buttonStyle(BrandButtonStyle())
                } else {
                    Button("Stop") { Task { await model.stop() } }.buttonStyle(BrandButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.stopPhase == .waiting)
                }
            }
        }
        .padding(26)
        .frame(width: 520)
        .background(Theme.card)
        .foregroundStyle(Theme.textPrimary)
        .preferredColorScheme(.light)
    }

    private var explanation: String {
        let others = group.members.count - 1
        let started = others > 0 ? " and the \(others) process\(others == 1 ? "" : "es") it started" : ""
        switch group.kind {
        case .agent(let name):
            return "This ends the \(name) session" + (group.root.tty.map { " in \($0)" } ?? "") + started + ". Anything it was in the middle of stops, and its conversation in that terminal ends."
        case .terminal:
            return "This stops the command running in " + (group.root.tty ?? "the terminal") + started + ". The terminal window stays open."
        case .orphan:
            return "Nothing is using it any more: the terminal or agent session that started it has ended. This stops it" + started + "."
        case .launchedBy(let app):
            return "This stops what \(app) started" + started + ". \(app) may start it again when it needs it."
        }
    }

    @ViewBuilder private var note: some View {
        switch model.stopPhase {
        case .confirm:
            Label("Lustro asks each process to quit first. Force Stop is offered only if one doesn't respond.", systemImage: "info.circle")
                .font(.lCaption).foregroundStyle(Theme.textTertiary)
        case .waiting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for it to stop…").font(.lCaption).foregroundStyle(Theme.textSecondary)
            }
        case .stillRunning:
            Label("Some processes didn't stop within 10 seconds. Force Stop ends them immediately.", systemImage: "exclamationmark.triangle.fill")
                .font(.lCaption).foregroundStyle(Theme.review)
        }
    }

    private func row(_ label: String, _ value: String, first: Bool = false) -> some View {
        HStack {
            Text(label).font(.lCaption).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value).font(.lCalloutStrong).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .overlay(alignment: .top) { if !first { Rectangle().fill(Theme.border).frame(height: 1) } }
    }
}
