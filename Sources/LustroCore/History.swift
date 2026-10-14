import Foundation

/// One removal run: what was removed, how, and where it went.
public struct HistoryEntry: Codable, Identifiable, Sendable, Equatable {
    public enum Status: String, Sendable { case inTrash, partlyRestored, restored, emptied, deletedPermanently, simulation }

    public let id: UUID
    public let date: Date
    public let module: String
    public let mode: RemovalMode
    public let dryRun: Bool
    public var items: [HistoryItem]
    /// Names of apps Lustro asked to quit before this run.
    public var quitApps: [String]

    public init(id: UUID = UUID(), date: Date = Date(), module: String, mode: RemovalMode, dryRun: Bool,
                items: [HistoryItem], quitApps: [String] = []) {
        self.id = id
        self.date = date
        self.module = module
        self.mode = mode
        self.dryRun = dryRun
        self.items = items
        self.quitApps = quitApps
    }

    public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    /// Items that can still be put back right now.
    public func restorableItems(fileManager: FileManager = .default) -> [HistoryItem] {
        items.filter { $0.canRestore(fileManager: fileManager) }
    }

    public func status(fileManager: FileManager = .default) -> Status {
        if dryRun { return .simulation }
        if mode == .permanent && items.allSatisfy({ $0.trashedPath == nil }) { return .deletedPermanently }
        let restored = items.filter(\.restored).count
        if restored == items.count { return .restored }
        if !restorableItems(fileManager: fileManager).isEmpty { return restored > 0 ? .partlyRestored : .inTrash }
        return .emptied
    }
}

public struct HistoryItem: Codable, Identifiable, Sendable, Equatable {
    public var id: String { originalPath }
    public let originalPath: String
    public let trashedPath: String?
    public let size: Int64
    public let rule: String?
    public var restored: Bool

    public init(originalPath: String, trashedPath: String?, size: Int64, rule: String?, restored: Bool = false) {
        self.originalPath = originalPath
        self.trashedPath = trashedPath
        self.size = size
        self.rule = rule
        self.restored = restored
    }

    /// True while the item is still in the Trash and nothing has taken its old place.
    public func canRestore(fileManager: FileManager = .default) -> Bool {
        guard !restored, let trashedPath else { return false }
        return fileManager.fileExists(atPath: trashedPath) && !fileManager.fileExists(atPath: originalPath)
    }
}

public enum RestoreError: Error, CustomStringConvertible {
    case notInTrash(String)
    case originalOccupied(String)

    public var description: String {
        switch self {
        case .notInTrash(let p): String(localized: "No longer in the Trash: \(p)")
        case .originalOccupied(let p): String(localized: "Something already exists at \(p)")
        }
    }
}

/// Removal history kept on this Mac only, in `~/Library/Application Support/Lustro/history.json`.
public final class HistoryStore: @unchecked Sendable {
    public let fileURL: URL
    public let limit: Int
    private let lock = NSLock()

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Lustro/history.json")
    }

    public init(fileURL: URL = HistoryStore.defaultURL, limit: Int = 200) {
        self.fileURL = fileURL
        self.limit = limit
    }

    public func load() -> [HistoryEntry] {
        lock.withLock { read() }
    }

    /// Records a finished removal. Returns the stored entry (nil when nothing was removed).
    @discardableResult
    public func record(module: String, report: RemovalReport, rules: [String: String] = [:], quitApps: [String] = []) -> HistoryEntry? {
        guard !report.removed.isEmpty else { return nil }
        let items = report.removed.map {
            HistoryItem(originalPath: $0.url.path, trashedPath: report.trashLocations[$0.id]?.path, size: $0.size, rule: rules[$0.id])
        }
        let entry = HistoryEntry(module: module, mode: report.mode, dryRun: report.dryRun, items: items, quitApps: quitApps)
        lock.withLock {
            var all = read()
            all.insert(entry, at: 0)
            write(Array(all.prefix(limit)))
        }
        return entry
    }

    /// Moves items back from the Trash to where they were. Returns the paths that failed and why.
    @discardableResult
    public func restore(entryID: UUID, itemIDs: Set<String>? = nil, fileManager: FileManager = .default) -> [String: String] {
        lock.withLock {
            var all = read()
            guard let index = all.firstIndex(where: { $0.id == entryID }) else { return [:] }
            var failures: [String: String] = [:]
            for i in all[index].items.indices {
                let item = all[index].items[i]
                guard itemIDs?.contains(item.id) ?? true, !item.restored else { continue }
                do {
                    guard let trashed = item.trashedPath, fileManager.fileExists(atPath: trashed) else {
                        throw RestoreError.notInTrash(item.originalPath)
                    }
                    guard !fileManager.fileExists(atPath: item.originalPath) else {
                        throw RestoreError.originalOccupied(item.originalPath)
                    }
                    let original = URL(fileURLWithPath: item.originalPath)
                    try fileManager.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.moveItem(at: URL(fileURLWithPath: trashed), to: original)
                    all[index].items[i].restored = true
                } catch {
                    failures[item.originalPath] = (error as? RestoreError)?.description ?? error.localizedDescription
                }
            }
            write(all)
            return failures
        }
    }

    public func clear() {
        lock.withLock { write([]) }
    }

    // MARK: - Storage (call with the lock held)

    private func read() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
    }

    private func write(_ entries: [HistoryEntry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(entries).write(to: fileURL, options: .atomic)
    }
}
