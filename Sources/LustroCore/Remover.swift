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
    /// Where each removed item ended up in the Trash, keyed by `ScanItem.id`.
    public internal(set) var trashLocations: [String: URL] = [:]
    public let dryRun: Bool
    public let mode: RemovalMode

    public var freedBytes: Int64 { removed.reduce(0) { $0 + $1.size } }
}

enum SystemAppError: Error, CustomStringConvertible {
    case trashOnly

    var description: String {
        String(localized: "Installed by the App Store, so it belongs to the system and can only be moved to the Trash. Choose Move to Trash in Settings and try again.")
    }
}

/// Removes items after re-validating each one against the safety policy.
public struct Remover: Sendable {
    public let policy: SafetyPolicy
    public let mode: RemovalMode
    public let dryRun: Bool
    /// Skip items another process has open (a running dev server's node_modules, a log being written…).
    public let skipOpenFiles: Bool
    /// Ask Finder (and so the user's password) for app bundles that belong to root. See `FinderTrash`.
    public let usesFinderForSystemApps: Bool

    public init(policy: SafetyPolicy, mode: RemovalMode = .trash, dryRun: Bool = false, skipOpenFiles: Bool = true,
                usesFinderForSystemApps: Bool = false) {
        self.policy = policy
        self.mode = mode
        self.dryRun = dryRun
        self.skipOpenFiles = skipOpenFiles
        self.usesFinderForSystemApps = usesFinderForSystemApps
    }

    public func remove(_ items: [ScanItem], progress: ProgressHandler? = nil) async -> RemovalReport {
        var report = RemovalReport(dryRun: dryRun, mode: mode)
        let fileManager = FileManager()
        let inUse = skipOpenFiles ? OpenFiles.holders(of: items.map(\.url)) : [:]
        for (index, item) in items.enumerated() {
            if Task.isCancelled { break }
            progress?(ScanProgress(message: item.url.lastPathComponent, fraction: Double(index) / Double(max(items.count, 1))))
            do {
                try policy.validate(item.url, fileManager: fileManager)
            } catch {
                report.failures.append(RemovalFailure(url: item.url, reason: error.description))
                continue
            }
            if let holders = inUse[item.url], !holders.isEmpty {
                let names = Array(Set(holders.map(\.name))).sorted().prefix(3).joined(separator: ", ")
                report.failures.append(RemovalFailure(url: item.url, reason: String(localized: "In use by \(names). Quit it and try again.")))
                continue
            }
            // Same path, different object: it was replaced after the scan, so it is not what the user reviewed.
            if let expected = item.fileID, FileID(of: item.url) != expected {
                report.failures.append(RemovalFailure(url: item.url, reason: String(localized: "Changed since it was scanned. Scan again.")))
                continue
            }
            if dryRun {
                report.removed.append(item)
                continue
            }
            do {
                // Moving something that is already in the Trash to the Trash does nothing. Decided on the
                // resolved location `validate` approved, so only the real ~/.Trash counts.
                let alreadyInTrash = SafetyPolicy.isStrictlyInside(SafetyPolicy.key(policy.resolvedLocation(of: item.url).path),
                                                                   SafetyPolicy.key(policy.home.appendingPathComponent(".Trash").path))
                switch alreadyInTrash ? .permanent : mode {
                case .trash:
                    var resulting: NSURL?
                    do {
                        try fileManager.trashItem(at: item.url, resultingItemURL: &resulting)
                    } catch where usesFinderForSystemApps && FinderTrash.isEligible(item.url) {
                        let url = item.url
                        resulting = try await MainActor.run { FinderTrash.trash(url) }.get() as NSURL?
                        guard FileID(of: item.url) == nil else { throw FinderTrashError.failed(item.url.path) }
                    }
                    if let resulting { report.trashLocations[item.id] = resulting as URL }
                case .permanent:
                    if usesFinderForSystemApps && FinderTrash.isEligible(item.url) { throw SystemAppError.trashOnly }
                    try fileManager.removeItem(at: item.url)
                }
                report.removed.append(item)
            } catch {
                let reason = (error as? FinderTrashError)?.description ?? (error as? SystemAppError)?.description
                    ?? error.localizedDescription
                report.failures.append(RemovalFailure(url: item.url, reason: reason))
            }
        }
        progress?(ScanProgress(message: "Done", fraction: 1))
        return report
    }
}
