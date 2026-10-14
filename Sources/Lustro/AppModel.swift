import AppKit
import LustroCore
import Observation

/// App-wide state: settings, permissions, rule catalog, removal history and disk usage.
@MainActor @Observable
final class AppModel {
    var settings: LustroSettings {
        didSet {
            guard settings != oldValue else { return }
            try? settings.save()
            if settings.appearance != oldValue.appearance { applyAppearance() }
            if settings.language != oldValue.language { applyLanguage() }
        }
    }
    /// The language chosen when Lustro started; a different choice takes effect after a restart.
    private let launchLanguage = LustroSettings.load().language
    var languageNeedsRestart: Bool { settings.language != launchLanguage }
    private(set) var hasFullDiskAccess = false
    let catalog: RuleCatalog?
    let catalogError: String?
    let history = HistoryStore()
    private(set) var historyEntries: [HistoryEntry] = []
    private(set) var disk: (total: Int64, available: Int64)?

    init() {
        LustroSettings.migrateFromPreviousName()
        settings = LustroSettings.load()
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

    /// The Cleanup scan: catalog categories plus leftovers of removed apps. Runs off the main thread.
    func cleanupScanner(catalog: RuleCatalog) -> @Sendable (@escaping ProgressHandler) async -> [ScanGroup] {
        let scanner = JunkScanner(catalog: catalog, policy: settings.policy(), hasFullDiskAccess: hasFullDiskAccess,
                                  disabledCategories: Set(settings.disabledCategories), keepNewestBackup: settings.keepNewestBackup)
        let wantsLeftovers = !settings.disabledCategories.contains(LeftoverScanner.groupID)
        let policy = settings.policy(), fullDiskAccess = hasFullDiskAccess
        return { progress in
            var groups = await scanner.scan(progress: progress)
            // The ownership check asks LaunchServices about every candidate.
            if wantsLeftovers, let group = LeftoverScanner(policy: policy, hasFullDiskAccess: fullDiskAccess,
                                                            isOwned: AppModel.leftoverOwnerCheck()).scan() {
                groups.append(group)
            }
            return groups
        }
    }

    /// Who still owns a bundle-ID-named folder: installed apps (LaunchServices knows them all, wherever they live),
    /// running apps, and working launch agents. Anything from the same vendor counts too (see LeftoverScanner).
    nonisolated static func leftoverOwnerCheck() -> LeftoverScanner.OwnerCheck {
        var known = Uninstaller().installedApps(measureSizes: false).map(\.bundleID)
        known += NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        known += LaunchItemScanner().scan(disabledLabels: []).filter { !$0.isBroken }.map(\.label)
        return LeftoverScanner.ownerCheck(knownIDs: known) { id in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
        }
    }

    /// Sets the appearance for every window, sheets included. Nil follows macOS.
    func applyAppearance() {
        switch settings.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// macOS reads the app's `AppleLanguages` default at launch.
    private func applyLanguage() {
        if let languages = settings.language.appleLanguages() {
            UserDefaults.standard.set(languages, forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }

    func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this instance to quit, then open the app again.
        task.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
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
