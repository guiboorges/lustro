import Foundation
import LimpoCore
import Observation

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

    private var task: Task<Void, Never>?

    var allItems: [ScanItem] { groups.flatMap(\.items) }
    var totalSize: Int64 { groups.reduce(0) { $0 + $1.totalSize } }
    var selectedItems: [ScanItem] { allItems.filter { selection.contains($0.id) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    /// Groups bucketed by section, keeping the scanner's order.
    var sections: [(name: String, groups: [ScanGroup])] {
        var order: [String] = []
        var buckets: [String: [ScanGroup]] = [:]
        for group in groups {
            if buckets[group.section] == nil { order.append(group.section) }
            buckets[group.section, default: []].append(group)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    func scan(using scanner: @escaping @Sendable (@escaping ProgressHandler) async -> [ScanGroup]) {
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
            selection = Set(result.filter(\.autoSelect).flatMap(\.items).map(\.id))
            expanded = []
            phase = .reviewing
        }
    }

    func remove(with remover: Remover, onRemoved: (@MainActor ([ScanItem]) -> Void)? = nil) {
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
            onRemoved?(report.removed)
            phase = .reviewing
        }
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

    func selectedSize(of group: ScanGroup) -> Int64 {
        group.items.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.size }
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
