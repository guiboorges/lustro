import AppKit
import LimpoCore
import Observation

/// App-wide state: settings, permissions and the rule catalog.
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
}
