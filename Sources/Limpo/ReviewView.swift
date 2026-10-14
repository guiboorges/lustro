import AppKit
import LimpoCore
import SwiftUI

/// Header + scan/review list + action bar, shared by Cleanup and Dev Purge.
struct ReviewView<EmptyContent: View, Accessory: View>: View {
    @Environment(AppModel.self) private var app
    let model: ReviewModel
    let module: String
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let scanner: @Sendable (@escaping ProgressHandler) async -> [ScanGroup]
    var activityDays: Int?
    @ViewBuilder var emptyContent: EmptyContent
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(title: title, subtitle: subtitle, symbol: symbol, tint: tint) {
                if model.phase == .scanning {
                    Button("Stop") { model.cancel() }
                } else {
                    Button(model.groups.isEmpty ? "Scan" : "Scan Again") { startScan() }
                        .keyboardShortcut("r")
                        .disabled(model.phase == .removing)
                }
            }
            content
        }
    }

    private func startScan() {
        model.scan(preselection: app.settings.preselection, using: scanner)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle:
            VStack(spacing: 16) {
                IconTile(symbol: symbol, tint: tint, size: 72)
                emptyContent
                Button { startScan() } label: {
                    Label("Scan", systemImage: "magnifyingglass").padding(.horizontal, 12).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .scanning:
            ScanningView(message: model.progressMessage, fraction: model.progressFraction)
        case .reviewing, .removing:
            if model.groups.isEmpty {
                ContentUnavailableView("Nothing to clean", systemImage: "sparkles",
                                       description: Text(model.lastReport == nil ? "Everything here is already tidy." : "All selected items were removed."))
                    .overlay(alignment: .top) { reportBanner }
            } else {
                VStack(spacing: 0) {
                    reportBanner
                    accessory
                    ReviewList(model: model, activityDays: activityDays)
                    ActionBar(model: model, module: module)
                }
            }
        }
    }

    @ViewBuilder private var reportBanner: some View {
        if let report = model.lastReport {
            ReportBanner(report: report) { model.dismissReport() }
                .padding(.horizontal, 28).padding(.bottom, 10)
        }
    }
}

struct ModuleHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            IconTile(symbol: symbol, tint: tint, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title.weight(.bold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            actions
        }
        .padding(.horizontal, 28)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }
}

struct ScanningView: View {
    let message: String
    let fraction: Double?

    var body: some View {
        VStack(spacing: 14) {
            if let fraction {
                ProgressView(value: fraction).frame(width: 280)
            } else {
                ProgressView().controlSize(.large)
            }
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ReviewList: View {
    @Bindable var model: ReviewModel
    var activityDays: Int?

    var body: some View {
        List {
            ForEach(model.sections, id: \.name) { section in
                Section {
                    ForEach(section.groups) { group in
                        GroupRow(model: model, group: group, activityDays: activityDays)
                        if model.expanded.contains(group.id) {
                            ForEach(group.items) { item in
                                ItemRow(model: model, item: item, group: group)
                                    .listRowBackground(Color.primary.opacity(0.025))
                            }
                        }
                    }
                } header: {
                    let total = section.groups.reduce(Int64(0)) { $0 + $1.totalSize }
                    HStack(spacing: 6) {
                        Text(section.name)
                        Text(total.formattedBytes).foregroundStyle(.tertiary).fontWeight(.regular)
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }
}

struct Checkbox: View {
    let state: ReviewModel.CheckState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(state == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state == .on ? "Selected" : state == .mixed ? "Partly selected" : "Not selected")
    }

    private var symbol: String {
        switch state {
        case .on: "checkmark.square.fill"
        case .mixed: "minus.square.fill"
        case .off: "square"
        }
    }
}

struct GroupRow: View {
    @Bindable var model: ReviewModel
    let group: ScanGroup
    var activityDays: Int?

    private var isActive: Bool {
        guard let days = activityDays, let last = group.lastActivity else { return false }
        return Date().timeIntervalSince(last) < Double(days) * 86_400
    }

    var body: some View {
        HStack(spacing: 10) {
            Checkbox(state: model.state(of: group)) { model.toggle(group) }
            Button {
                if model.expanded.contains(group.id) { model.expanded.remove(group.id) } else { model.expanded.insert(group.id) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(model.expanded.contains(group.id) ? 90 : 0))
                    IconTile(symbol: group.icon ?? "folder",
                             tint: Palette.color(group.tint ?? Palette.tint(forSection: group.section)))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(group.title).font(.body.weight(.semibold))
                            RiskBadge(risk: group.risk)
                            if isActive { Badge(text: "Active", tint: .blue) }
                        }
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(group.totalSize.formattedBytes).font(.body.weight(.semibold).monospacedDigit())
                        Text(itemSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 5)
    }

    private var detail: String {
        guard let last = group.lastActivity else { return group.detail }
        return "\(group.detail) · \(isActive ? "edited" : "last touched") \(last.relativeDescription)"
    }

    /// Names for small groups ("node_modules · .next"), a count otherwise.
    private var itemSummary: String {
        if group.items.count <= 3 {
            return group.items.map(\.url.lastPathComponent).joined(separator: " · ")
        }
        return "\(group.items.count) items"
    }
}

struct ItemRow: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: ReviewModel
    let item: ScanItem
    let group: ScanGroup
    @State private var showWhy = false

    var body: some View {
        HStack(spacing: 10) {
            Checkbox(state: model.selection.contains(item.id) ? .on : .off) { model.toggle(item) }
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(item.url.deletingLastPathComponent().path.abbreviatingHome)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            if let note = item.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            } else if let date = item.lastModified {
                Text(date.relativeDescription).font(.caption).foregroundStyle(.secondary)
            }
            Text(item.size.formattedBytes).font(.callout.monospacedDigit()).frame(minWidth: 70, alignment: .trailing)
            Button { showWhy.toggle() } label: {
                Label("Why?", systemImage: "info.circle").font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .popover(isPresented: $showWhy, arrowEdge: .bottom) {
                WhyView(item: item, group: group)
            }
        }
        .padding(.leading, 44)
        .contextMenu {
            Button("Show in Finder") { app.reveal(item.url) }
            Button("Always Ignore") {
                app.ignore(item.url)
                model.selection.remove(item.id)
            }
        }
    }
}

/// "Why is this safe?" — the classification reasons for one item.
struct WhyView: View {
    @Environment(AppModel.self) private var app
    let item: ScanItem
    let group: ScanGroup

    var body: some View {
        let running = AppOwnership().runningOwners(of: item.url, explicitOwners: group.owners, running: ActionBar.runningApps())
        let reasons = Explainer(policy: app.settings.policy())
            .reasons(for: item, in: group, ownerName: app.ownerName(for: item.url, explicitOwners: group.owners), runningOwners: running)
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(group.risk == .caution ? "Why is this listed?" : "Why is this safe?").font(.headline)
            } icon: {
                Image(systemName: group.risk == .caution ? "exclamationmark.shield" : "checkmark.shield")
                    .foregroundStyle(group.risk == .caution ? .orange : .green)
            }
            ForEach(reasons, id: \.self) { reason in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol(for: reason.kind))
                        .foregroundStyle(color(for: reason.kind))
                        .frame(width: 14)
                    Text(reason.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            HStack {
                Text("Rule \(group.id) · \(group.risk.rawValue.capitalized)")
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Always Ignore") { app.ignore(item.url) }
                    .buttonStyle(.link).font(.caption.weight(.semibold))
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func symbol(for kind: Reason.Kind) -> String {
        switch kind {
        case .ok: "checkmark"
        case .warning: "exclamationmark.triangle"
        case .info: "info.circle"
        }
    }

    private func color(for kind: Reason.Kind) -> Color {
        switch kind {
        case .ok: .green
        case .warning: .orange
        case .info: .blue
        }
    }
}

struct RiskBadge: View {
    let risk: RiskLevel

    var body: some View {
        switch risk {
        case .safe: EmptyView()
        case .review: Badge(text: "Review", tint: .orange)
        case .caution: Badge(text: "Caution", tint: .red)
        }
    }
}

struct ActionBar: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: ReviewModel
    let module: String
    var extraAllowedRoots: [URL] = []
    var actionTitle: String?
    var onRemoved: (@MainActor ([ScanItem]) -> Void)?
    @State private var confirming = false
    @State private var conflicts: [AppConflict] = []
    @State private var quitting = false
    @State private var quitApps: [(name: String, url: URL?)] = []

    private var permanent: Bool { app.settings.removalMode == .permanent }

    var body: some View {
        HStack(spacing: 12) {
            Checkbox(state: model.selection.isEmpty ? .off : model.selection.count == model.allItems.count ? .on : .mixed) {
                model.selectAll(model.selection.isEmpty)
            }
            Text("\(model.selectedItems.count) of \(model.allItems.count) selected")
                .foregroundStyle(.secondary)
            Spacer()
            if model.phase == .removing || quitting {
                ProgressView(value: model.progressFraction ?? 0).frame(width: 120)
            }
            Label(app.settings.dryRun ? "Dry run" : permanent ? "Deletes permanently" : "Moves to Trash",
                  systemImage: app.settings.dryRun ? "eye" : permanent ? "trash" : "arrow.uturn.backward")
                .font(.caption)
                .foregroundStyle(permanent && !app.settings.dryRun ? .red : .secondary)
            Text(model.selectedSize.formattedBytes).font(.title3.monospacedDigit().weight(.bold))
            Button(actionTitle ?? (permanent ? "Delete…" : "Move to Trash…")) { start() }
                .buttonStyle(.borderedProminent)
                .tint(permanent ? .red : .accentColor)
                .controlSize(.large)
                .disabled(model.selection.isEmpty || model.phase == .removing || quitting)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button(permanent ? "Delete Permanently" : "Move to Trash", role: permanent ? .destructive : nil) { performRemoval() }
        } message: {
            Text(confirmMessage)
        }
        .sheet(isPresented: Binding(get: { !conflicts.isEmpty }, set: { if !$0 { conflicts = [] } })) {
            RunningAppsSheet(conflicts: conflicts, reopens: app.settings.reopenAppsAfterCleaning,
                             onQuit: { quitAndContinue() },
                             onSkip: { skipAndContinue() },
                             onCancel: { conflicts = [] })
        }
    }

    /// Checks for open apps that own selected files before asking for confirmation.
    private func start() {
        quitApps = []
        let found = model.runningConflicts(with: Self.runningApps())
        if found.isEmpty { confirming = true } else { conflicts = found }
    }

    private func skipAndContinue() {
        for conflict in conflicts { model.selection.subtract(conflict.items.map(\.id)) }
        conflicts = []
        if !model.selection.isEmpty { confirming = true }
    }

    private func quitAndContinue() {
        let pids = Set(conflicts.map(\.app.pid))
        let targets = NSWorkspace.shared.runningApplications.filter { pids.contains($0.processIdentifier) }
        let pending = conflicts
        conflicts = []
        quitting = true
        targets.forEach { $0.terminate() }
        Task { @MainActor in
            // Give apps up to 10 seconds to save and quit; files of apps still open are skipped.
            for _ in 0..<40 where !targets.allSatisfy(\.isTerminated) {
                try? await Task.sleep(for: .milliseconds(250))
            }
            let stillOpen = Set(targets.filter { !$0.isTerminated }.map(\.processIdentifier))
            for conflict in pending where stillOpen.contains(conflict.app.pid) {
                model.selection.subtract(conflict.items.map(\.id))
            }
            quitApps = targets.filter(\.isTerminated).map { ($0.localizedName ?? "App", $0.bundleURL) }
            quitting = false
            if !model.selection.isEmpty { confirming = true } else { reopenQuitApps() }
        }
    }

    private func performRemoval() {
        let remover = Remover(policy: app.settings.policy(extraAllowedRoots: extraAllowedRoots),
                              mode: app.settings.removalMode, dryRun: app.settings.dryRun)
        let rules = model.ruleIDs
        model.remove(with: remover) { report in
            app.record(module: module, report: report, rules: rules, quitApps: quitApps.map(\.name))
            onRemoved?(report.removed)
            reopenQuitApps()
        }
    }

    /// Reopens apps Limpo asked to quit, in the background, if the user wants that.
    private func reopenQuitApps() {
        defer { quitApps = [] }
        guard app.settings.reopenAppsAfterCleaning else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        for url in quitApps.compactMap(\.url) {
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    }

    /// Apps the user can quit: regular Dock apps only. Helpers, menu-bar agents and system
    /// processes are left out, and the Finder is never asked to quit.
    static func runningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid()
                && $0.bundleIdentifier != "com.apple.finder" }
            .compactMap { app in
                app.bundleIdentifier.map {
                    RunningApp(bundleID: $0, name: app.localizedName ?? $0, pid: app.processIdentifier)
                }
            }
    }

    private var confirmTitle: String {
        "\(permanent ? "Delete" : "Move") \(model.selectedItems.count) item\(model.selectedItems.count == 1 ? "" : "s") (\(model.selectedSize.formattedBytes))?"
    }

    private var confirmMessage: String {
        if app.settings.dryRun { return "Dry run is on: nothing will actually be removed." }
        return permanent
            ? "This cannot be undone. Items already in the Trash are always deleted permanently."
            : "You can put items back from History until you empty the Trash. Items already in the Trash are deleted permanently."
    }
}

struct RunningAppsSheet: View {
    let conflicts: [AppConflict]
    let reopens: Bool
    let onQuit: () -> Void
    let onSkip: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Some apps are open").font(.title3.weight(.semibold))
                    Text("Removing files of an app while it runs can make it misbehave until it restarts. Quit these apps first\(reopens ? " — Limpo reopens them when it's done —" : "") or leave their files for now.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(conflicts.enumerated()), id: \.element.id) { index, conflict in
                    HStack(spacing: 10) {
                        if let icon = NSRunningApplication(processIdentifier: conflict.app.pid)?.icon {
                            Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                        }
                        Text(conflict.app.name).fontWeight(.semibold)
                        Spacer()
                        Text("\(conflict.items.count) item\(conflict.items.count == 1 ? "" : "s") · \(conflict.size.formattedBytes)")
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    if index < conflicts.count - 1 { Divider() }
                }
            }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            Text("Apps that don't quit within 10 seconds keep their files. Nothing is force-quit.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Skip Their Files", action: onSkip)
                Button("Quit Apps and Continue", action: onQuit)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(22)
        .frame(width: 480)
    }
}

struct ReportBanner: View {
    let report: RemovalReport
    let dismiss: () -> Void
    @State private var showFailures = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: report.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(report.failures.isEmpty ? .green : .orange)
                Text(summary).font(.callout.weight(.medium))
                Spacer()
                if !report.failures.isEmpty {
                    Button(showFailures ? "Hide Details" : "Details") { showFailures.toggle() }.buttonStyle(.link)
                }
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            if showFailures {
                ForEach(report.failures) { failure in
                    Text("\(failure.url.path.abbreviatingHome): \(failure.reason)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var summary: String {
        let verb = report.dryRun ? "Would free" : (report.mode == .trash ? "Moved to Trash" : "Freed")
        var text = "\(verb) \(report.freedBytes.formattedBytes) · \(report.removed.count) item\(report.removed.count == 1 ? "" : "s")"
        if !report.dryRun && report.mode == .trash { text += " · undo from History" }
        if !report.failures.isEmpty { text += " · \(report.failures.count) skipped" }
        return text
    }
}

extension String {
    var abbreviatingHome: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return hasPrefix(home) ? "~" + dropFirst(home.count) : self
    }
}
