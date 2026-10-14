import AppKit
import LustroCore
import SwiftUI

/// What's slowing the Mac down right now, what starts on its own, and a few safe tune-ups.
struct MaintenanceView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: MaintenanceModel

    var body: some View {
        VStack(spacing: 16) {
            PanelHeader(title: "Maintenance",
                        subtitle: "What's slowing your Mac down right now, plus a few safe tune-ups. Nothing runs until you click.") {
                Button("Activity Monitor") {
                    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
                                                       configuration: NSWorkspace.OpenConfiguration())
                }
                .buttonStyle(OutlineButtonStyle())
                Button("Refresh") { Task { await refreshAll() } }.buttonStyle(InkButtonStyle())
            }
            vitals
            HStack(alignment: .top, spacing: 16) {
                ProcessesCard(model: model)
                LaunchItemsCard(model: model).frame(width: 392)
            }
            .frame(maxHeight: .infinity)
            TuneUpsSection(model: model)
            Label("No “Free up RAM” button: macOS keeps spare memory as cache, so forcing it free only makes apps slower to reopen.",
                  systemImage: "info.circle")
                .font(.lCaption).foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { model.isVisible = true }
        .onDisappear { model.isVisible = false }
        .task { await refreshAll() }
        .sheet(item: $model.quitTarget) { process in
            QuitProcessSheet(model: model, process: process)
        }
    }

    private func refreshAll() async {
        await model.sampleNow()
        await model.refreshLaunchItems()
        await model.refreshTuneUps()
    }

    private var vitals: some View {
        let v = model.vitals
        let cpu = v?.cpuPercent ?? model.cpuHistory.last
        return HStack(spacing: 16) {
            KPICard(label: "CPU load", value: cpu.map { "\(Int($0.rounded()))" } ?? "–", unit: "%",
                    detail: v.map { String(format: "Load %.1f · ", $0.loadAverage) + (model.runaway != nil ? "1 runaway process" : "\($0.coreCount) cores") } ?? "Measuring…",
                    bars: model.cpuHistory.count > 1 ? model.cpuHistory.map { max($0, 1) } : nil)
            KPICard(label: "Memory pressure", value: v.map { pressure($0.memoryPressure) } ?? "–", unit: "",
                    detail: v.map { "\(Int(Double($0.memoryUsed) / Double(max($0.memoryTotal, 1)) * 100))% in use · " + ($0.swapUsed > 0 ? "\($0.swapUsed.formattedBytes) swap" : "no swap") } ?? "")
            KPICard(label: "Temperature", value: v.map { thermal($0.thermalState).0 } ?? "–", unit: "",
                    detail: v.map { thermal($0.thermalState).1 } ?? "")
        }
    }

    private func pressure(_ p: SystemVitals.MemoryPressure) -> String {
        switch p {
        case .normal: "Normal"
        case .warning: "Elevated"
        case .critical: "High"
        }
    }

    private func thermal(_ state: ProcessInfo.ThermalState) -> (String, String) {
        switch state {
        case .nominal: ("Normal", "No throttling")
        case .fair: ("Warm", "Fans may be running faster · no throttling")
        case .serious: ("Hot", "macOS is slowing things down to cool off")
        case .critical: ("Very hot", "Heavily throttled until it cools down")
        @unknown default: ("–", "")
        }
    }
}

// MARK: - Heavy processes

private struct ProcessesCard: View {
    let model: MaintenanceModel

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Heavy processes").font(.lTitle3)
                    Text("Sorted by \(model.sort == .cpu ? "CPU" : "memory") · refreshes every 5 seconds")
                        .font(.lCaption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Segmented(options: [(MaintenanceModel.SortKey.cpu, "CPU"), (.memory, "Memory")], selection: $model.sort, ink: true)
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
            if let runaway = model.runaway {
                RunawayBanner(process: runaway) { model.askToQuit(runaway) }
                    .padding(.horizontal, 12).padding(.bottom, 6)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.visibleProcesses) { process in
                        ProcessRow(process: process, cores: model.vitals?.coreCount ?? 8,
                                   isRunaway: process.pid == model.runaway?.pid) { model.askToQuit(process) }
                    }
                }
            }
            .scrollIndicators(.hidden)
            if model.processes.isEmpty {
                ProgressView().controlSize(.small).frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .lustroCard()
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct RunawayBanner: View {
    let process: ProcessSample
    let quit: () -> Void

    var body: some View {
        let advice = ProcessAdvisor.advice(for: process)
        HStack(spacing: 14) {
            Tile(symbol: "bolt", background: Theme.orange500, foreground: Theme.onBrand, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(advice.headline).font(.lBodyStrong).foregroundStyle(Theme.onBrand)
                Text(advice.detail).font(.lCaption).foregroundStyle(Theme.onBrandMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Quit Process", action: quit).buttonStyle(BrandButtonStyle())
        }
        .padding(.leading, 14).padding(.trailing, 16).padding(.vertical, 14)
        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ProcessRow: View {
    let process: ProcessSample
    let cores: Int
    let isRunaway: Bool
    let quit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Tile(symbol: isRunaway ? "bolt" : process.isSystem ? "cpu" : process.appPath == nil ? "terminal" : "shippingbox",
                 background: isRunaway ? Theme.caution.opacity(0.12) : Theme.peach100,
                 foreground: isRunaway ? Theme.caution : Theme.rust700, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(process.name).font(.lCalloutStrong).lineLimit(1)
                Text(subtitle).font(.lCaption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            HStack(spacing: 8) {
                Capsule().fill(Theme.sunken).frame(width: 64, height: 6)
                    .overlay(alignment: .leading) {
                        Capsule().fill(isRunaway ? Theme.caution : Theme.orange500)
                            .frame(width: max(5, 64 * min(process.cpuPercent / Double(max(cores, 1) * 100), 1)), height: 6)
                    }
                Text("\(Int(process.cpuPercent.rounded()))%").font(.lCalloutStrong).monospacedDigit()
                    .foregroundStyle(isRunaway ? Theme.caution : Theme.textPrimary)
                    .frame(width: 46, alignment: .trailing)
            }
            Text(process.memory.formattedBytes).font(.lCaption).foregroundStyle(Theme.textSecondary).monospacedDigit()
                .lineLimit(1).frame(width: 62, alignment: .trailing)
            Group {
                if process.isSystem {
                    Chip(text: "System", tone: .neutral).fixedSize()
                } else {
                    Button("Quit", action: quit).buttonStyle(PillButtonStyle(tint: isRunaway ? Theme.caution : Theme.textPrimary))
                }
            }
            .frame(width: 72, alignment: .trailing)
        }
        .padding(.leading, 20).padding(.trailing, 16).padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        .help(process.path)
    }

    private var subtitle: String {
        var parts: [String] = []
        if process.isSystem {
            parts.append("macOS")
        } else if let app = process.appName {
            parts.append(process.isAppMain ? "App" : app)
        } else {
            parts.append((process.path as NSString).deletingLastPathComponent.abbreviatingHome)
        }
        if let running = process.runningTime, running >= 3600 { parts.append("running \(ProcessAdvisor.formatHours(running))") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Launch agents

private struct LaunchItemsCard: View {
    @Environment(AppModel.self) private var app
    let model: MaintenanceModel

    var body: some View {
        let broken = model.launchItems.filter(\.isBroken).count
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Runs at login").font(.lTitle3)
                    Text("\(model.launchItems.count) item\(model.launchItems.count == 1 ? "" : "s")"
                         + (broken == 1 ? " · 1 points to a missing app" : broken > 1 ? " · \(broken) point to missing apps" : ""))
                        .font(.lCaption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("See all") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.plain).font(.lCalloutStrong).foregroundStyle(Theme.rust700)
                .help("Open Login Items in System Settings")
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.launchItems) { item in row(item) }
                }
            }
            .scrollIndicators(.hidden)
            Label("Turning an item off never deletes it.", systemImage: "info.circle")
                .font(.lCaption).foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 14)
                .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .lustroCard()
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func row(_ item: LaunchItem) -> some View {
        let name = model.launchNames[item.id] ?? nil
        return HStack(spacing: 12) {
            Tile(symbol: item.isBroken ? "exclamationmark.triangle" : "power",
                 background: item.isBroken ? Theme.orange500.opacity(0.14) : Theme.peach100,
                 foreground: item.isBroken ? Theme.review : Theme.rust700, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(name ?? item.label).font(.lCalloutStrong).lineLimit(1).truncationMode(.middle)
                Text(subtitle(item, appName: name)).font(.lCaption)
                    .foregroundStyle(item.isBroken ? Theme.review : Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if item.canRemove {
                Button("Remove") { Task { await model.remove(item, app: app) } }.buttonStyle(PillButtonStyle(tint: Theme.textPrimary))
                    .help("Move to the Trash. You can put it back from History.")
            } else if item.isBroken || item.scope == .system {
                Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([item.plist]) }.buttonStyle(PillButtonStyle(tint: Theme.textPrimary))
                    .help("Removing it needs an administrator. Show it in Finder.")
            } else {
                Toggle("", isOn: Binding(get: { !item.isDisabled }, set: { on in Task { await model.setEnabled(on, item) } }))
                    .toggleStyle(LustroToggleStyle()).labelsHidden().fixedSize()
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        .help(item.plist.path)
    }

    private func subtitle(_ item: LaunchItem, appName: String?) -> String {
        if item.isBroken { return item.appPath != nil ? "Its app was deleted" : "Its program is missing" }
        let kind = item.scope == .system ? "Background service" : "Launch agent"
        if appName != nil { return "\(kind) · \(item.label)" }
        return "\(kind) · " + (item.scope == .user ? "just you" : "all users")
    }
}

// MARK: - Tune-ups

private struct TuneUpsSection: View {
    let model: MaintenanceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label { Text("Tune-ups").overline() } icon: { Image(systemName: "wrench.adjustable").foregroundStyle(Theme.rust700) }
                .font(.system(size: 11, weight: .semibold))
            HStack(spacing: 16) {
                card(.snapshots, symbol: "clock.arrow.circlepath", title: "Local snapshots",
                     detail: "Time Machine copies on this disk, freed when space runs low.",
                     meta: model.snapshots.isEmpty ? (model.purgeable > 0 ? "\(model.purgeable.formattedBytes) purgeable" : "No snapshots")
                         : "\(model.purgeable.formattedBytes) · \(model.snapshots.count) snapshot\(model.snapshots.count == 1 ? "" : "s")",
                     action: "Thin", ink: true)
                card(.mail, symbol: "envelope", title: "Speed up Mail",
                     detail: "Compacts Mail's index. Mail needs to be closed first.",
                     meta: model.mailIndexSize.map { "Index is \($0.formattedBytes)" } ?? "Needs Full Disk Access", action: "Run")
                card(.dns, symbol: "globe", title: "Flush DNS cache",
                     detail: "For sites that won't load after a network change.", meta: "Asks for password", action: "Run")
                card(.spotlight, symbol: "magnifyingglass", title: "Rebuild Spotlight",
                     detail: "Only if search misses files. Can take hours.", meta: "Asks for password", action: "Run")
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func card(_ tuneUp: MaintenanceModel.TuneUp, symbol: String, title: String, detail: String,
                      meta: String, action: String, ink: Bool = false) -> some View {
        let status = model.tuneUps[tuneUp]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Tile(symbol: symbol, size: 32)
                Text(title).font(.lCalloutStrong).lineLimit(1)
            }
            Text(detail).font(.lCaption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: .infinity, alignment: .top)
            HStack(spacing: 8) {
                switch status {
                case .running:
                    ProgressView().controlSize(.small)
                    Text("Working…").font(.lCaption).foregroundStyle(Theme.textSecondary)
                case .done(let message):
                    Label(message, systemImage: "checkmark.circle.fill").font(.lCaption).foregroundStyle(Theme.safe).lineLimit(1)
                case .failed(let message):
                    Text(message).font(.lCaption).foregroundStyle(Theme.review).lineLimit(1).help(message)
                case nil:
                    Text(meta).font(.lCaption).foregroundStyle(Theme.textPrimary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button(action) { Task { await model.run(tuneUp) } }
                    .buttonStyle(TuneUpButtonStyle(ink: ink))
                    .disabled(status == .running)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .lustroCard()
    }
}

/// Compact 30 pt button used on the tune-up cards.
private struct TuneUpButtonStyle: ButtonStyle {
    let ink: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.lCalloutStrong)
            .foregroundStyle(ink ? Theme.onBrand : Theme.textPrimary)
            .padding(.horizontal, 14).frame(height: 30)
            .background(ink ? Theme.ink : (configuration.isPressed ? Theme.sunken : Theme.card),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay { if !ink { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border) } }
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

// MARK: - Quit sheet

struct QuitProcessSheet: View {
    let model: MaintenanceModel
    let process: ProcessSample

    var body: some View {
        let advice = ProcessAdvisor.advice(for: process)
        VStack(alignment: .leading, spacing: 16) {
            Tile(symbol: "bolt", background: Theme.caution.opacity(0.12), foreground: Theme.caution, size: 52)
            Text("Quit \(process.name)?").font(.lTitle2)
            Text(advice.quitEffect).font(.lCallout).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                detailRow("Process", "\(process.name) · PID \(process.pid)")
                detailRow("Using", "\(Int(process.cpuPercent.rounded()))% CPU · " + String(format: "about %.1f cores", process.cpuPercent / 100),
                          tint: process.cpuPercent >= ProcessAdvisor.runawayCPU ? Theme.caution : Theme.textPrimary)
                if let running = process.runningTime { detailRow("Running for", ProcessAdvisor.formatHours(running)) }
                if let app = process.appName { detailRow("Part of", app) }
            }
            .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            note
            HStack(spacing: 10) {
                Button("Cancel") { model.quitTarget = nil }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                if advice.findURL != nil {
                    Button("Find the Tab") { model.findTab(for: process) }.buttonStyle(OutlineButtonStyle())
                        .help("Opens about:processes in Firefox (the address is also copied, in case it doesn't open).")
                }
                if model.quitPhase == .stillRunning {
                    Button("Force Quit") { Task { await model.forceQuit() } }.buttonStyle(BrandButtonStyle())
                } else {
                    Button("Quit Process") { Task { await model.quit() } }.buttonStyle(BrandButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.quitPhase == .waiting)
                }
            }
        }
        .padding(26)
        .frame(width: 520)
        .background(Theme.card)
        .foregroundStyle(Theme.textPrimary)
        .preferredColorScheme(.light)
    }

    @ViewBuilder private var note: some View {
        switch model.quitPhase {
        case .confirm:
            Label("Lustro asks it to quit first. Force Quit is offered only if it doesn't respond.", systemImage: "info.circle")
                .font(.lCaption).foregroundStyle(Theme.textTertiary)
        case .waiting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for it to quit…").font(.lCaption).foregroundStyle(Theme.textSecondary)
            }
        case .stillRunning:
            Label("It didn't quit within 10 seconds. Force Quit stops it immediately; anything unsaved in it is lost.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.lCaption).foregroundStyle(Theme.review)
        }
    }

    private func detailRow(_ label: String, _ value: String, tint: Color = Theme.textPrimary) -> some View {
        HStack {
            Text(label).font(.lCaption).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value).font(.lCalloutStrong).foregroundStyle(tint).lineLimit(1)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .overlay(alignment: .top) { if label != "Process" { Rectangle().fill(Theme.border).frame(height: 1) } }
    }
}
