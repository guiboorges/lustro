import AppKit
import LustroCore
import SwiftUI

/// Header + scan/review list + floating action bar, shared by Cleanup and Dev Purge.
struct ReviewView<EmptyContent: View, Accessory: View>: View {
    @Environment(AppModel.self) private var app
    let model: ReviewModel
    let module: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let symbol: String
    let scanner: @Sendable (@escaping ProgressHandler) async -> [ScanGroup]
    var activityDays: Int?
    @ViewBuilder var emptyContent: EmptyContent
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(spacing: 18) {
            PanelHeader(title: title, subtitle: subtitle) {
                if model.phase == .scanning {
                    Button("Stop") { model.cancel() }.buttonStyle(OutlineButtonStyle())
                } else {
                    Button(model.groups.isEmpty ? "Scan" : "Scan Again") { startScan() }
                        .buttonStyle(OutlineButtonStyle())
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
            PanelPlaceholder(symbol: symbol, title: "Ready when you are", message: "Scanning only reads your disk. Nothing is removed until you review it.") {
                emptyContent
                Button("Scan") { startScan() }.buttonStyle(BrandButtonStyle())
            }
        case .scanning:
            ScanningView(message: model.progressMessage, fraction: model.progressFraction)
        case .reviewing, .removing:
            if model.groups.isEmpty {
                PanelPlaceholder(symbol: "sparkles", title: "Nothing to clean",
                                 message: model.lastReport == nil ? "Everything here is already tidy." : "All selected items were removed.") {
                    if let report = model.lastReport { ReportBanner(report: report) { model.dismissReport() }.frame(maxWidth: 520) }
                }
            } else {
                VStack(spacing: 16) {
                    if let report = model.lastReport {
                        ReportBanner(report: report) { model.dismissReport() }
                    }
                    accessory
                    ReviewList(model: model, activityDays: activityDays)
                    ActionBar(model: model, module: module)
                }
            }
        }
    }
}

struct ScanningView: View {
    let message: String
    let fraction: Double?

    var body: some View {
        VStack(spacing: 16) {
            if let fraction {
                ProgressView(value: fraction).frame(width: 280)
            } else {
                ProgressView().controlSize(.large)
            }
            Text(L(message)).font(.lCallout).foregroundStyle(Theme.textSecondary)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .lustroCard(radius: 22)
    }
}

struct ReviewList: View {
    @Bindable var model: ReviewModel
    var activityDays: Int?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.sections, id: \.name) { section in
                    let total = section.groups.reduce(Int64(0)) { $0 + $1.totalSize }
                    SectionHeader(title: L(section.name), detail: total.formattedBytes)
                    ForEach(section.groups) { group in
                        GroupRow(model: model, group: group, activityDays: activityDays)
                        if model.expanded.contains(group.id) {
                            ForEach(group.items) { item in
                                ItemRow(model: model, item: item, group: group)
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .lustroCard()
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
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
        let colors = Palette.tile(group.risk == .caution ? "red" : group.tint)
        HStack(spacing: 12) {
            Checkbox(state: model.state(of: group)) { model.toggle(group) }
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    if model.expanded.contains(group.id) { model.expanded.remove(group.id) } else { model.expanded.insert(group.id) }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(model.expanded.contains(group.id) ? 90 : 0))
                    Tile(symbol: group.icon ?? "folder", background: colors.background, foreground: colors.foreground)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(L(group.title)).font(.lBodyStrong)
                            RiskChip(risk: group.risk)
                            if isActive { Chip(text: "Active", tone: .neutral) }
                        }
                        Text(detail).font(.lCaption).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(group.totalSize.formattedBytes).font(.lTitle3).monospacedDigit()
                        Text(itemSummary).font(.lCaption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 18).padding(.trailing, 20).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var detail: String {
        let text = L(group.detail)
        guard let last = group.lastActivity else { return text }
        return isActive ? String(localized: "\(text) · edited \(last.relativeDescription)")
            : String(localized: "\(text) · last touched \(last.relativeDescription)")
    }

    private var itemSummary: String {
        if group.items.count <= 3 {
            return group.items.map(\.url.lastPathComponent).joined(separator: " · ")
        }
        return String(localized: "\(group.items.count) items")
    }
}

struct ItemRow: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: ReviewModel
    let item: ScanItem
    let group: ScanGroup
    @State private var showWhy = false

    var body: some View {
        HStack(spacing: 12) {
            Checkbox(state: model.selection.contains(item.id) ? .on : .off) { model.toggle(item) }
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.url.lastPathComponent).font(.lCalloutStrong).lineLimit(1).truncationMode(.middle)
                Text(item.url.deletingLastPathComponent().path.abbreviatingHome)
                    .font(.lCaption).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            if let note = item.note {
                Text(L(note)).font(.lCaption).foregroundStyle(Theme.textSecondary)
            } else if let date = item.lastModified {
                Text(date.relativeDescription).font(.lCaption).foregroundStyle(Theme.textSecondary)
            }
            Text(item.size.formattedBytes).font(.lCalloutStrong).monospacedDigit().frame(minWidth: 72, alignment: .trailing)
            Button { showWhy.toggle() } label: { Label("Why?", systemImage: "info.circle") }
                .buttonStyle(PillButtonStyle())
                .popover(isPresented: $showWhy, arrowEdge: .bottom) { WhyView(item: item, group: group) }
        }
        .padding(.leading, 66).padding(.trailing, 20).padding(.vertical, 10)
        .background(Theme.sunken)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
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
        let caution = group.risk == .caution
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Tile(symbol: caution ? "exclamationmark.shield" : "checkmark.shield",
                     background: (caution ? Theme.review : Theme.safe).opacity(0.12),
                     foreground: caution ? Theme.review : Theme.safe, size: 30)
                Text(caution ? "Why is this listed?" : "Why is this safe?").font(.lTitle3)
            }
            ForEach(reasons, id: \.self) { reason in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: symbol(for: reason.kind))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(color(for: reason.kind))
                        .frame(width: 14)
                    Text(reason.text).font(.lCallout).fixedSize(horizontal: false, vertical: true)
                }
            }
            Rectangle().fill(Theme.border).frame(height: 1).padding(.top, 2)
            HStack {
                Text("Rule \(group.id)").font(.lCaption).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Always Ignore") { app.ignore(item.url) }
                    .buttonStyle(.plain).font(.lCaption).foregroundStyle(Theme.rust700)
            }
        }
        .padding(18)
        .frame(width: 350)
        .background(Theme.card)
        .foregroundStyle(Theme.textPrimary)
    }

    private func symbol(for kind: Reason.Kind) -> String {
        switch kind {
        case .ok: "checkmark"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle"
        }
    }

    private func color(for kind: Reason.Kind) -> Color {
        switch kind {
        case .ok: Theme.safe
        case .warning: Theme.review
        case .info: Theme.orange500
        }
    }
}

struct ActionBar: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: ReviewModel
    let module: String
    var extraAllowedRoots: [URL] = []
    var actionTitle: LocalizedStringKey?
    var onRemoved: (@MainActor ([ScanItem]) -> Void)?
    @State private var confirming = false
    @State private var conflicts: [AppConflict] = []
    @State private var quitting = false
    @State private var quitApps: [(name: String, url: URL?)] = []

    private var permanent: Bool { app.settings.removalMode == .permanent }

    var body: some View {
        FloatingBar {
            Checkbox(state: model.selection.isEmpty ? .off : model.selection.count == model.allItems.count ? .on : .mixed, onDark: true) {
                model.selectAll(model.selection.isEmpty)
            }
            Text("\(model.selectedItems.count) of \(model.allItems.count) selected").font(.lCallout).foregroundStyle(Theme.onBrandMuted)
            Spacer()
            if model.phase == .removing || quitting {
                ProgressView(value: model.progressFraction ?? 0).frame(width: 120).tint(Theme.orange500)
            }
            Label(app.settings.dryRun ? "Dry run" : permanent ? "Deletes permanently" : "Moves to Trash",
                  systemImage: app.settings.dryRun ? "eye" : permanent ? "trash" : "arrow.uturn.backward")
                .font(.lCaption)
                .foregroundStyle(permanent && !app.settings.dryRun ? Color(hex: 0xFF9C8A) : Theme.onBrandMuted)
            Text(model.selectedSize.formattedBytes).font(.lTitle2).foregroundStyle(Theme.onBrand).monospacedDigit()
            Button(actionTitle ?? (permanent ? "Delete…" : "Move to Trash")) { start() }
                .buttonStyle(BrandButtonStyle())
                .disabled(model.selection.isEmpty || model.phase == .removing || quitting)
        }
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

    /// Reopens apps Lustro asked to quit, in the background, if the user wants that.
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
        let count = model.selectedItems.count, size = model.selectedSize.formattedBytes
        switch (permanent, count == 1) {
        case (true, true): return String(localized: "Delete 1 item (\(size))?")
        case (true, false): return String(localized: "Delete \(count) items (\(size))?")
        case (false, true): return String(localized: "Move 1 item to the Trash (\(size))?")
        case (false, false): return String(localized: "Move \(count) items to the Trash (\(size))?")
        }
    }

    private var confirmMessage: String {
        if app.settings.dryRun { return String(localized: "Dry run is on: nothing will actually be removed.") }
        return permanent
            ? String(localized: "This cannot be undone. Items already in the Trash are always deleted permanently.")
            : String(localized: "You can put items back from History until you empty the Trash. Items already in the Trash are deleted permanently.")
    }
}

struct RunningAppsSheet: View {
    let conflicts: [AppConflict]
    let reopens: Bool
    let onQuit: () -> Void
    let onSkip: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Tile(symbol: "exclamationmark.triangle", background: Theme.orange500.opacity(0.14), foreground: Theme.review, size: 52)
            Text("Some apps are open").font(.lTitle2)
            Text(reopens ? "Removing an app's files while it runs can make it misbehave until it restarts. Quit them first — Lustro reopens them when it's done — or leave their files for now."
                 : "Removing an app's files while it runs can make it misbehave until it restarts. Quit them first or leave their files for now.")
                .font(.lCallout).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(Array(conflicts.enumerated()), id: \.element.id) { index, conflict in
                    HStack(spacing: 12) {
                        if let icon = NSRunningApplication(processIdentifier: conflict.app.pid)?.icon {
                            Image(nsImage: icon).resizable().frame(width: 34, height: 34)
                        }
                        Text(conflict.app.name).font(.lBodyStrong)
                        Spacer()
                        Text(conflict.items.count == 1 ? "1 item · \(conflict.size.formattedBytes)" : "\(conflict.items.count) items · \(conflict.size.formattedBytes)")
                            .font(.lCaption).foregroundStyle(Theme.textSecondary).monospacedDigit()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    if index < conflicts.count - 1 { Rectangle().fill(Theme.border).frame(height: 1) }
                }
            }
            .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Label("Apps that don't quit within 10 seconds keep their files. Nothing is force-quit.", systemImage: "arrow.triangle.2.circlepath")
                .font(.lCaption).foregroundStyle(Theme.textTertiary)
            HStack(spacing: 10) {
                Button("Cancel", action: onCancel).buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Skip Their Files", action: onSkip).buttonStyle(OutlineButtonStyle())
                Button("Quit Apps and Continue", action: onQuit).buttonStyle(BrandButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 520)
        .background(Theme.card)
        .foregroundStyle(Theme.textPrimary)
    }
}

struct ReportBanner: View {
    let report: RemovalReport
    let dismiss: () -> Void
    @State private var showFailures = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: report.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(report.failures.isEmpty ? Theme.safe : Theme.review)
                Text(summary).font(.lCalloutStrong)
                Spacer()
                if !report.failures.isEmpty {
                    Button(showFailures ? "Hide Details" : "Details") { showFailures.toggle() }
                        .buttonStyle(.plain).font(.lCaption).foregroundStyle(Theme.rust700)
                }
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
            }
            if showFailures {
                ForEach(report.failures) { failure in
                    Text("\(failure.url.path.abbreviatingHome): \(failure.reason)")
                        .font(.lCaption).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background((report.failures.isEmpty ? Theme.safe : Theme.review).opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var summary: String {
        let size = report.freedBytes.formattedBytes
        var parts = [report.dryRun ? String(localized: "Would free \(size)")
                     : report.mode == .trash ? String(localized: "Moved to Trash \(size)") : String(localized: "Freed \(size)")]
        parts.append(report.removed.count == 1 ? String(localized: "1 item") : String(localized: "\(report.removed.count) items"))
        if !report.dryRun && report.mode == .trash { parts.append(String(localized: "undo from History")) }
        if !report.failures.isEmpty { parts.append(String(localized: "\(report.failures.count) skipped")) }
        return parts.joined(separator: " · ")
    }
}
