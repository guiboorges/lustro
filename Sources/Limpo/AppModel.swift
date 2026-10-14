import AppKit
import LimpoCore
import Observation

/// App-wide state: settings, permissions, rule catalog, removal history and disk usage.
@MainActor @Observable
final class AppModel {
    var settings: LimpoSettings {
        didSet {
            guard settings != oldValue else { return }
            try? settings.save()
        }
    }
    private(set) var hasFullDiskAccess = false
    let catalog: RuleCatalog?
    let catalogError: String?
    let history = HistoryStore()
    private(set) var historyEntries: [HistoryEntry] = []
    private(set) var disk: (total: Int64, available: Int64)?

    init() {
        settings = LimpoSettings.load()
        do {
            catalog = try RuleCatalog.bundled()
            catalogError = nil
        } catch {
            catalog = nil
            catalogError = error.localizedDescription
        }
        refreshPermissions()
        reloadHistory()
        refreshDisk()
    }

    /// Full Disk Access can't be queried directly; reading the user TCC database succeeds only with it.
    func refreshPermissions() {
        let tcc = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        if let handle = try? FileHandle(forReadingFrom: tcc) {
            try? handle.close()
            hasFullDiskAccess = true
        } else {
            hasFullDiskAccess = false
        }
    }

    func refreshDisk() {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage else { return }
        disk = (Int64(total), available)
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func ignore(_ url: URL) {
        let path = url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        if !settings.ignoredPaths.contains(path) { settings.ignoredPaths.append(path) }
    }

    /// Display name of the app that owns `url`, resolved through LaunchServices.
    func ownerName(for url: URL, explicitOwners: [String]) -> String? {
        let key = AppOwnership().ownerKey(for: url)
        for id in [key].compactMap({ $0 }) + explicitOwners where id.contains(".") {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
            }
        }
        return nil
    }

    // MARK: - History

    func reloadHistory() {
        historyEntries = history.load()
    }

    func record(module: String, report: RemovalReport, rules: [String: String], quitApps: [String]) {
        history.record(module: module, report: report, rules: rules, quitApps: quitApps)
        reloadHistory()
        refreshDisk()
    }

    @discardableResult
    func restore(_ entry: HistoryEntry, items: Set<String>? = nil) -> [String: String] {
        let failures = history.restore(entryID: entry.id, itemIDs: items)
        reloadHistory()
        refreshDisk()
        return failures
    }
}
