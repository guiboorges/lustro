import AppKit
import LustroCore
import SwiftUI

struct CleanupView: View {
    @Environment(AppModel.self) private var app
    let model: ReviewModel

    var body: some View {
        if let catalog = app.catalog {
            let scanner = JunkScanner(
                catalog: catalog,
                policy: app.settings.policy(),
                hasFullDiskAccess: app.hasFullDiskAccess,
                disabledCategories: Set(app.settings.disabledCategories),
                keepNewestBackup: app.settings.keepNewestBackup
            )
            ReviewView(model: model, module: "Cleanup", title: "Cleanup",
                       subtitle: "Caches, logs and leftovers from apps, developer tools and AI tools.",
                       symbol: Module.cleanup.symbol,
                       scanner: { progress in await scanner.scan(progress: progress) }) {
                if !app.hasFullDiskAccess { FullDiskAccessHint() }
            } accessory: {
                HStack(spacing: 16) {
                    SummaryCard(model: model)
                    StatusCard(symbol: app.settings.removalMode == .trash ? "checkmark.shield" : "exclamationmark.shield",
                               tint: app.settings.removalMode == .trash && !app.settings.dryRun ? Theme.safe : Theme.review,
                               title: app.settings.dryRun ? "Dry run is on" : app.settings.removalMode == .trash ? "Goes to the Trash" : "Deletes permanently",
                               detail: app.settings.dryRun ? "Nothing will actually be removed" : app.settings.removalMode == .trash ? "Put anything back from History" : "Can't be undone · change in Settings")
                    let open = model.runningConflicts(with: ActionBar.runningApps())
                    StatusCard(symbol: open.isEmpty ? "checkmark.circle" : "exclamationmark.triangle",
                               tint: open.isEmpty ? Theme.safe : Theme.review,
                               title: open.isEmpty ? "No open apps affected" : "\(open.count) app\(open.count == 1 ? " is" : "s are") open",
                               detail: open.isEmpty ? "Nothing needs to quit" : "Their files wait until they quit")
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            PanelPlaceholder(symbol: "exclamationmark.triangle", title: "Rules could not be loaded", message: app.catalogError ?? "") { EmptyView() }
        }
    }
}

/// Selected total with a segmented bar per section.
struct SummaryCard: View {
    let model: ReviewModel

    var body: some View {
        let totals = model.sectionTotals
        let found = max(model.totalSize, 1)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(number(model.selectedSize)).font(.lMetric).monospacedDigit()
                Text("\(unit(model.selectedSize)) selected").font(.lTitle3).foregroundStyle(Theme.textSecondary)
                Text("of \(model.totalSize.formattedBytes) found · \(model.selectedItems.count) of \(model.allItems.count) items")
                    .font(.lCallout).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            GeometryReader { geo in
                HStack(spacing: 3) {
                    ForEach(Array(totals.enumerated()), id: \.element.name) { index, section in
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Palette.sectionColor(index).opacity(section.selected > 0 ? 1 : 0.35))
                            .frame(width: max(geo.size.width * CGFloat(section.total) / CGFloat(found) - 3, 4))
                    }
                }
            }
            .frame(height: 10)
            HStack(spacing: 16) {
                ForEach(Array(totals.enumerated()), id: \.element.name) { index, section in
                    HStack(spacing: 6) {
                        Circle().fill(Palette.sectionColor(index).opacity(section.selected > 0 ? 1 : 0.35)).frame(width: 8, height: 8)
                        Text("\(section.name) \(section.total.formattedBytes)\(section.selected == 0 ? " · not selected" : "")")
                            .font(.lCaption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .lustroCard()
    }
}

struct StatusCard: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Tile(symbol: symbol, background: tint.opacity(0.12), foreground: tint, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.lCalloutStrong)
                Text(detail).font(.lCaption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 232)
        .frame(maxHeight: .infinity)
        .lustroCard()
    }
}

struct DevPurgeView: View {
    enum Filter: Hashable { case all, inactive, largest }

    @Environment(AppModel.self) private var app
    let model: ReviewModel
    @State private var filter: Filter = .all

    var body: some View {
        let roots = app.settings.resolvedProjectRoots
        let days = app.settings.inactiveDaysForAutoSelect
        let scanner = ProjectArtifactScanner(roots: roots, policy: app.settings.policy(), inactiveDaysForAutoSelect: days)
        ReviewView(model: model, module: "Dev Purge", title: "Dev Purge",
                   subtitle: "Build folders and dependencies your projects can rebuild — only flagged when a project file proves what they are.",
                   symbol: Module.devPurge.symbol,
                   scanner: { progress in await scanner.scan(progress: progress) },
                   activityDays: days) {
            Text("Looks in " + roots.map { $0.path.abbreviatingHome }.joined(separator: " · "))
                .font(.lCaption).foregroundStyle(Theme.textSecondary)
        } accessory: {
            VStack(spacing: 16) {
                let inactive = model.groups.filter { ($0.lastActivity ?? .distantPast) < Date().addingTimeInterval(-Double(days) * 86_400) }
                let largest = model.allItems.max { $0.size < $1.size }
                HStack(spacing: 16) {
                    KPICard(label: "Rebuildable", value: number(model.totalSize), unit: unit(model.totalSize),
                            detail: "in \(model.groups.count) projects · \(model.allItems.count) folders",
                            bars: model.groups.prefix(5).map { Double($0.totalSize) }.reversed())
                    KPICard(label: "Inactive \(days)+ days", value: "\(inactive.count)", unit: "projects",
                            detail: "\(inactive.reduce(Int64(0)) { $0 + $1.totalSize }.formattedBytes) preselected")
                    KPICard(label: "Largest", value: largest.map { number($0.size) } ?? "–", unit: largest.map { unit($0.size) } ?? "",
                            detail: largest.map { "\($0.url.lastPathComponent) · \($0.url.deletingLastPathComponent().lastPathComponent)" } ?? "")
                }
                HStack(spacing: 12) {
                    Segmented(options: [(.all, "All projects"), (.inactive, "Inactive \(days)+ days"), (.largest, "Largest first")], selection: $filter)
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "folder").foregroundStyle(Theme.textSecondary)
                        Text(roots.map { $0.path.abbreviatingHome }.joined(separator: " · ")).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(Theme.textSecondary)
                        Button("Change") { addRoot() }.buttonStyle(.plain).foregroundStyle(Theme.rust700)
                    }
                    .font(.lCaption)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
                }
            }
        }
        .onChange(of: filter, initial: true) { _, value in
            model.sortLargestFirst = value == .largest
            let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
            model.groupFilter = value == .inactive ? { ($0.lastActivity ?? .distantPast) < cutoff } : nil
        }
    }

    private func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose folders that contain your projects"
        guard panel.runModal() == .OK else { return }
        var roots = app.settings.projectRoots.isEmpty ? app.settings.resolvedProjectRoots.map { $0.path.abbreviatingHome } : app.settings.projectRoots
        for url in panel.urls where !roots.contains(url.path.abbreviatingHome) { roots.append(url.path.abbreviatingHome) }
        app.settings.projectRoots = roots
    }
}

struct FullDiskAccessHint: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield").foregroundStyle(Theme.review)
            Text("Grant Full Disk Access to include sandboxed app caches, Mail downloads and iPhone backups.")
                .font(.lCaption).foregroundStyle(Theme.textSecondary)
            Button("Open Settings") { app.openFullDiskAccessSettings() }.buttonStyle(.plain).font(.lCaption).foregroundStyle(Theme.rust700)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: 600)
    }
}
