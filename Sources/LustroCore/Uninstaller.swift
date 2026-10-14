import Foundation

/// An installed application that can be uninstalled.
public struct InstalledApp: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let bundleID: String
    public let version: String?
    public let size: Int64
}

/// Finds installed apps and the files they leave behind.
///
/// Leftovers are matched only by exact bundle identifier (or `bundleID.` prefix for
/// helpers and extensions) and, in a few name-keyed folders, by the exact app name.
/// No fuzzy matching: a missed leftover is better than deleting another app's data.
public struct Uninstaller: Sendable {
    public let home: URL
    public let searchRoots: [URL]
    public let policy: SafetyPolicy
    public let knowledgeBase: AppKnowledgeBase

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                searchRoots: [URL]? = nil,
                ignoredPaths: [URL] = [],
                knowledgeBase: AppKnowledgeBase = .bundled()) {
        self.home = home
        self.knowledgeBase = knowledgeBase
        self.searchRoots = searchRoots ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        self.policy = SafetyPolicy(home: home, extraAllowedRoots: self.searchRoots, ignoredPaths: ignoredPaths)
    }

    /// Bundle identifiers that are never offered for removal.
    static func isProtectedBundle(_ id: String) -> Bool {
        id.hasPrefix("com.apple.") || id == Bundle.main.bundleIdentifier
    }

    public func installedApps(measureSizes: Bool = true) -> [InstalledApp] {
        var apps: [InstalledApp] = []
        var seen = Set<String>()
        for root in searchRoots {
            for url in appBundles(in: root, depth: 2) {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                      !Self.isProtectedBundle(id), seen.insert(url.resolvingSymlinksInPath().path).inserted else { continue }
                let info = bundle.infoDictionary ?? [:]
                let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                apps.append(InstalledApp(
                    url: url, name: name, bundleID: id,
                    version: info["CFBundleShortVersionString"] as? String,
                    size: measureSizes ? DiskUsage.allocatedSize(of: url) : 0
                ))
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func appBundles(in folder: URL, depth: Int) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
        var result: [URL] = []
        for entry in entries {
            if entry.pathExtension == "app" {
                result.append(entry)
            } else if depth > 1,
                      (try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
                        .map({ $0.isDirectory == true && $0.isSymbolicLink != true }) == true {
                result += appBundles(in: entry, depth: depth - 1)
            }
        }
        return result
    }

    /// The app bundle plus every leftover found for it, grouped for review.
    public func removalPlan(for app: InstalledApp) -> [ScanGroup] {
        var groups: [ScanGroup] = []
        if let bundle = DiskUsage.item(for: app.url) {
            groups.append(ScanGroup(id: "app", title: "Application", detail: app.url.path,
                                    section: app.name, risk: .review, autoSelect: true, owners: [app.bundleID],
                                    icon: "shippingbox", tint: "pink", items: [bundle]))
        }
        let leftovers = leftovers(bundleID: app.bundleID, name: app.name)
        // Data the knowledge base protects (profiles, vaults, unsynced files) is offered separately and never preselected.
        let (support, data) = (leftovers.filter { knowledgeBase.protectingApp(for: $0.url, home: home) == nil },
                               leftovers.filter { knowledgeBase.protectingApp(for: $0.url, home: home) != nil })
        let extra = knowledgeBaseFiles(bundleID: app.bundleID)
            .filter { url in !leftovers.contains { SafetyPolicy.isSameOrInside(url.standardizedFileURL.path, $0.url.path) } }
            .compactMap { DiskUsage.item(for: $0) }
        let supportItems = support + extra.filter { knowledgeBase.protectingApp(for: $0.url, home: home) == nil }
        let dataItems = data + extra.filter { knowledgeBase.protectingApp(for: $0.url, home: home) != nil }
        if !supportItems.isEmpty {
            groups.append(ScanGroup(id: "leftovers", title: "Support files",
                                    detail: "Preferences, caches, containers and other files created by the app",
                                    section: app.name, risk: .review, autoSelect: true, owners: [app.bundleID],
                                    icon: "lock.shield", tint: "indigo", items: supportItems.sorted { $0.size > $1.size }))
        }
        if !dataItems.isEmpty {
            let why = knowledgeBase.app(forBundleID: app.bundleID)?.why ?? "Data you may want to keep."
            groups.append(ScanGroup(id: "app-data", title: "Your data in \(app.name)", detail: why,
                                    section: app.name, risk: .caution, autoSelect: false, owners: [app.bundleID],
                                    icon: "person.crop.square", tint: "red", items: dataItems.sorted { $0.size > $1.size }))
        }
        return groups
    }

    /// Paths the knowledge base lists for this app outside the standard bundle-ID folders. Paths shared with
    /// other apps (e.g. ~/Library/CloudStorage) are left out: they aren't this app's alone.
    func knowledgeBaseFiles(bundleID: String) -> [URL] {
        guard let entry = knowledgeBase.app(forBundleID: bundleID) else { return [] }
        let others = knowledgeBase.apps.filter { !$0.bundleIDs.contains(bundleID) }
            .flatMap { ($0.never ?? []) + ($0.files ?? []).map(\.path) }
        let own = (entry.never ?? []) + (entry.files ?? []).map(\.path)
        var seen = Set<String>()
        return own.filter { !others.contains($0) }
            .flatMap { PathPattern.expand($0, home: home) }
            .filter { policy.isAllowed($0) && seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Files in `~/Library` that belong to `bundleID`.
    public func leftovers(bundleID: String, name: String) -> [ScanItem] {
        let lib = home.appendingPathComponent("Library")
        let id = bundleID
        var urls: [URL] = []

        func add(_ relative: String) {
            urls += PathPattern.expand(lib.appendingPathComponent(relative).path, home: home)
        }
        func escaped(_ s: String) -> String {
            s.replacingOccurrences(of: "[", with: "[[]").replacingOccurrences(of: "*", with: "[*]").replacingOccurrences(of: "?", with: "[?]")
        }
        let e = escaped(id)
        let n = escaped(name)

        // Keyed by bundle identifier.
        for folder in ["Application Support", "Caches", "HTTPStorages", "WebKit", "Containers", "Application Scripts", "Logs"] {
            add("\(folder)/\(e)")
            add("\(folder)/\(e).*")
        }
        add("Preferences/\(e).plist")
        add("Preferences/\(e).*.plist")
        add("Preferences/ByHost/\(e).*.plist")
        add("Saved Application State/\(e).savedState")
        add("HTTPStorages/\(e).binarycookies")
        add("Cookies/\(e).binarycookies")
        add("LaunchAgents/\(e).plist")
        add("LaunchAgents/\(e).*.plist")
        add("Group Containers/*.\(e)")
        add("Group Containers/*.\(e).*")

        // Keyed by app name, only in folders where apps conventionally use their name.
        if name.count >= 3 {
            for folder in ["Application Support", "Caches", "Logs"] {
                add("\(folder)/\(n)")
            }
        }

        var seen = Set<String>()
        return urls
            .filter { seen.insert($0.standardizedFileURL.path).inserted && policy.isAllowed($0) }
            .compactMap { DiskUsage.item(for: $0) }
            .sorted { $0.size > $1.size }
    }
}
