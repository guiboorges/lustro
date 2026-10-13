import Foundation

public enum RemovalMode: String, Codable, Sendable, CaseIterable {
    /// Move to the Trash so the user can restore. The default.
    case trash
    /// Delete immediately. Cannot be undone.
    case permanent
}

public struct RemovalFailure: Sendable, Identifiable {
    public var id: String { url.path }
    public let url: URL
    public let reason: String
}

public struct RemovalReport: Sendable {
    public internal(set) var removed: [ScanItem] = []
    public internal(set) var failures: [RemovalFailure] = []
    public let dryRun: Bool
    public let mode: RemovalMode

    public var freedBytes: Int64 { removed.reduce(0) { $0 + $1.size } }
}

/// Removes items after re-validating each one against the safety policy.
public struct Remover: Sendable {
    public let policy: SafetyPolicy
    public let mode: RemovalMode
    public let dryRun: Bool

    public init(policy: SafetyPolicy, mode: RemovalMode = .trash, dryRun: Bool = false) {
        self.policy = policy
        self.mode = mode
        self.dryRun = dryRun
    }

    public func remove(_ items: [ScanItem], progress: ProgressHandler? = nil) async -> RemovalReport {
        var report = RemovalReport(dryRun: dryRun, mode: mode)
        let fileManager = FileManager()
        for (index, item) in items.enumerated() {
            if Task.isCancelled { break }
            progress?(ScanProgress(message: item.url.lastPathComponent, fraction: Double(index) / Double(max(items.count, 1))))
            do {
                try policy.validate(item.url, fileManager: fileManager)
            } catch {
                report.failures.append(RemovalFailure(url: item.url, reason: error.description))
                continue
            }
            if dryRun {
                report.removed.append(item)
                continue
            }
            do {
                // Moving something that is already in the Trash to the Trash does nothing.
                let alreadyInTrash = SafetyPolicy.isStrictlyInside(item.url.standardizedFileURL.path,
                                                                   policy.home.appendingPathComponent(".Trash").path)
                switch alreadyInTrash ? .permanent : mode {
                case .trash:
                    try fileManager.trashItem(at: item.url, resultingItemURL: nil)
                case .permanent:
                    try fileManager.removeItem(at: item.url)
                }
                report.removed.append(item)
            } catch {
                report.failures.append(RemovalFailure(url: item.url, reason: error.localizedDescription))
            }
        }
        progress?(ScanProgress(message: "Done", fraction: 1))
        return report
    }
}
