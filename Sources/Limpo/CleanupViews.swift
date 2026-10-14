import AppKit
import LimpoCore
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
                       symbol: "sparkles", tint: Module.cleanup.tint,
                       scanner: { progress in await scanner.scan(progress: progress) }) {
                VStack(spacing: 8) {
                    Text("\(scanner.activeCategories.count) categories ready to scan").font(.title3)
                    if !app.hasFullDiskAccess { FullDiskAccessHint() }
                }
            } accessory: {
                SummaryCard(model: model)
            }
        } else {
            ContentUnavailableView("Rules could not be loaded", systemImage: "exclamationmark.triangle",
                                   description: Text(app.catalogError ?? ""))
        }
    }
}

/// Big selected total, a per-section bar and the safety summary.
struct SummaryCard: View {
    @Environment(AppModel.self) private var app
    let model: ReviewModel

    var body: some View {
        let totals = model.sectionTotals
        let found = max(model.totalSize, 1)
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(model.selectedSize.formattedBytes).font(.largeTitle.weight(.bold).monospacedDigit())
                    Text("selected of \(model.totalSize.formattedBytes) found · \(model.selectedItems.count) of \(model.allItems.count) items")
                        .font(.callout).foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(totals, id: \.name) { section in
                            let tint = Palette.color(Palette.tint(forSection: section.name))
                            let width = geo.size.width * CGFloat(section.total) / CGFloat(found)
                            ZStack(alignment: .leading) {
                                Rectangle().fill(tint.opacity(0.25))
                                Rectangle().fill(tint)
                                    .frame(width: width * CGFloat(section.selected) / CGFloat(max(section.total, 1)))
                            }
                            .frame(width: max(width - 2, 0))
                        }
                    }
                }
                .frame(height: 8)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                HStack(spacing: 16) {
                    ForEach(totals, id: \.name) { section in
                        HStack(spacing: 6) {
                            Circle().fill(Palette.color(Palette.tint(forSection: section.name)).opacity(section.selected > 0 ? 1 : 0.35))
                                .frame(width: 8, height: 8)
                            Text("\(section.name) \(section.total.formattedBytes)\(section.selected == 0 ? " · not selected" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Divider().frame(height: 60)
            VStack(alignment: .leading, spacing: 10) {
                SafetyLine(symbol: app.settings.removalMode == .trash ? "checkmark.shield" : "exclamationmark.shield",
                           tint: app.settings.removalMode == .trash ? .green : .red,
                           title: app.settings.dryRun ? "Dry run is on" : app.settings.removalMode == .trash ? "Goes to the Trash" : "Deletes permanently",
                           detail: app.settings.dryRun ? "Nothing will actually be removed" : app.settings.removalMode == .trash ? "Put anything back from History" : "Can't be undone. Change this in Settings")
                let open = model.runningConflicts(with: ActionBar.runningApps())
                if !open.isEmpty {
                    SafetyLine(symbol: "exclamationmark.triangle", tint: .orange,
                               title: "\(open.count) app\(open.count == 1 ? " is" : "s are") open",
                               detail: "Their files wait until they quit")
                }
            }
            .frame(width: 250, alignment: .leading)
        }
        .padding(16)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .padding(.horizontal, 28)
        .padding(.bottom, 8)
    }
}

struct SafetyLine: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct DevPurgeView: View {
    enum Filter: String, CaseIterable { case all = "All projects", inactive = "Inactive", largest = "Largest first" }

    @Environment(AppModel.self) private var app
    let model: ReviewModel
    @State private var filter: Filter = .all

    var body: some View {
        let roots = app.settings.resolvedProjectRoots
        let days = app.settings.inactiveDaysForAutoSelect
        let scanner = ProjectArtifactScanner(roots: roots, policy: app.settings.policy(), inactiveDaysForAutoSelect: days)
        ReviewView(model: model, module: "Dev Purge", title: "Dev Purge",
                   subtitle: "Build folders and dependencies your projects can rebuild. Only flagged when a project file proves what they are.",
                   symbol: "hammer", tint: Module.devPurge.tint,
                   scanner: { progress in await scanner.scan(progress: progress) },
                   activityDays: days) {
            VStack(spacing: 8) {
                Text("Looks for projects in:").font(.title3)
                Text(roots.map { $0.path.abbreviatingHome }.joined(separator: " · "))
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
                Text("Projects untouched for \(days)+ days are preselected.").font(.caption).foregroundStyle(.secondary)
            }
        } accessory: {
            HStack(spacing: 12) {
                Picker("Show", selection: $filter) {
                    Text("All projects").tag(Filter.all)
                    Text("Inactive \(days)+ days").tag(Filter.inactive)
                    Text("Largest first").tag(Filter.largest)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Label(roots.map { $0.path.abbreviatingHome }.joined(separator: " · "), systemImage: "folder")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Button("Change…") { addRoot() }.buttonStyle(.link).font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 8)
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
        HStack(spacing: 8) {
            Image(systemName: "lock.shield").foregroundStyle(.orange)
            Text("Grant Full Disk Access to also clean sandboxed app caches, Mail downloads and device backups.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Open Settings") { app.openFullDiskAccessSettings() }.buttonStyle(.link)
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 560)
    }
}
