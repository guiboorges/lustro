import Foundation
import LimpoCore
import Observation

struct AppConflict: Identifiable {
    var id: String { app.bundleID }
    let app: RunningApp
    let items: [ScanItem]
    var size: Int64 { items.reduce(0) { $0 + $1.size } }
}

/// Scan → review → remove workflow shared by Cleanup, Dev Purge and the Uninstaller.
@MainActor @Observable
final class ReviewModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case reviewing
        case removing
    }

    private(set) var phase: Phase = .idle
    private(set) var progressMessage = ""
    private(set) var progressFraction: Double?
    private(set) var groups: [ScanGroup] = []
    private(set) var lastReport: RemovalReport?
    var selection = Set<String>()
    var expanded = Set<String>()
    /// Optional view filter (e.g. Dev Purge "inactive only") and ordering.
    var groupFilter: ((ScanGroup) -> Bool)?
    var sortLargestFirst = false

    private var task: Task<Void, Never>?

    var allItems: [ScanItem] { groups.flatMap(\.items) }
    var totalSize: Int64 { groups.reduce(0) { $0 + $1.totalSize } }
    var selectedItems: [ScanItem] { allItems.filter { selection.contains($0.id) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var visibleGroups: [ScanGroup] {
        let filtered = groupFilter.map { groups.filter($0) } ?? groups
        return sortLargestFirst ? filtered.sorted { $0.totalSize > $1.totalSize } : filtered
    }

    /// Groups bucketed by section, keeping the scanner's order.
    var sections: [(name: String, groups: [ScanGroup])] {
        var order: [String] = []
        var buckets: [String: [ScanGroup]] = [:]
        for group in visibleGroups {
            if buckets[group.section] == nil { order.append(group.section) }
            buckets[group.section, default: []].append(group)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    /// Total and selected size per section, for the summary bar.
    var sectionTotals: [(name: String, total: Int64, selected: Int64)] {
        sections.map { section in
            let items = section.groups.flatMap(\.items)
            return (section.name, items.reduce(0) { $0 + $1.size },
                    items.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.size })
        }
    }

    func group(containing item: ScanItem) -> ScanGroup? {
        groups.first { $0.items.contains { $0.id == item.id } }
    }

    func scan(preselection: PreselectionMode = .smart,
              using scanner: @escaping @Sendable (@escaping ProgressHandler) async -> [ScanGroup]) {
        task?.cancel()
        phase = .scanning
        progressMessage = "Starting…"
        progressFraction = nil
        lastReport = nil
        let progress = progressHandler()
        task = Task {
            let result = await Task.detached(priority: .userInitiated) { await scanner(progress) }.value
            guard !Task.isCancelled else { return }
            groups = result
            applyPreselection(preselection)
            expanded = []
            phase = .reviewing
        }
    }

    func applyPreselection(_ mode: PreselectionMode) {
        let chosen: [ScanGroup] = switch mode {
        case .off: []
        case .smart: groups.filter(\.autoSelect)
        case .allSafe: groups.filter { $0.risk != .caution }
        }
        selection = Set(chosen.flatMap(\.items).map(\.id))
    }

    func remove(with remover: Remover, onFinished: (@MainActor (RemovalReport) -> Void)? = nil) {
        let items = selectedItems
        guard !items.isEmpty else { return }
        phase = .removing
        progressMessage = ""
        progressFraction = 0
        let progress = progressHandler()
        task = Task {
            let report = await Task.detached(priority: .userInitiated) { await remover.remove(items, progress: progress) }.value
            lastReport = report
            if !report.dryRun {
                let removed = Set(report.removed.map(\.id))
                groups = groups.compactMap { group in
                    var g = group
                    g.items.removeAll { removed.contains($0.id) }
                    return g.items.isEmpty ? nil : g
                }
                selection.subtract(removed)
            }
            onFinished?(report)
            phase = .reviewing
        }
    }

    /// Rule (group) each selected item came from, for the removal history.
    var ruleIDs: [String: String] {
        Dictionary(groups.flatMap { g in g.items.map { ($0.id, g.id) } }, uniquingKeysWith: { a, _ in a })
    }

    func cancel() {
        task?.cancel()
        phase = groups.isEmpty ? .idle : .reviewing
    }

    func reset() {
        task?.cancel()
        groups = []
        selection = []
        lastReport = nil
        phase = .idle
    }

    func dismissReport() { lastReport = nil }

    // MARK: - Selection

    enum CheckState { case on, off, mixed }

    func state(of group: ScanGroup) -> CheckState {
        let selected = group.items.filter { selection.contains($0.id) }.count
        if selected == 0 { return .off }
        return selected == group.items.count ? .on : .mixed
    }

    func toggle(_ group: ScanGroup) {
        let ids = group.items.map(\.id)
        if state(of: group) == .on { selection.subtract(ids) } else { selection.formUnion(ids) }
    }

    func toggle(_ item: ScanItem) {
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    func selectAll(_ on: Bool) {
        selection = on ? Set(allItems.map(\.id)) : []
    }

    // MARK: - Running apps

    /// Selected items that belong to apps that are currently open, grouped by app.
    func runningConflicts(with running: [RunningApp]) -> [AppConflict] {
        let ownership = AppOwnership()
        var byApp: [String: (RunningApp, [ScanItem])] = [:]
        for group in groups {
            for item in group.items where selection.contains(item.id) {
                for app in ownership.runningOwners(of: item.url, explicitOwners: group.owners, running: running) {
                    byApp[app.bundleID, default: (app, [])].1.append(item)
                }
            }
        }
        return byApp.values
            .map { AppConflict(app: $0.0, items: $0.1) }
            .sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
    }

    private func progressHandler() -> ProgressHandler {
        { [weak self] p in
            Task { @MainActor in
                self?.progressMessage = p.message
                self?.progressFraction = p.fraction
            }
        }
    }
}
