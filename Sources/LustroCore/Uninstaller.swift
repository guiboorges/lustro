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
///
/// The identifier and name come from the app's own Info.plist, which anyone can write, so they are
/// treated as untrusted: they must be a single path component, prefix matching needs a full
/// reverse-DNS identifier, and every match must sit directly in the folder it was looked up in.
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
        self.searchRoots = searchRoots ?? Self.defaultSearchRoots(home: home)
        self.policy = SafetyPolicy(home: home, extraAllowedRoots: self.searchRoots, ignoredPaths: ignoredPaths)
    }

    public static func defaultSearchRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
    }

    /// Bundle identifiers that are never offered for removal. Compared without case, like the file system.
    static func isProtectedBundle(_ id: String) -> Bool {
        let id = id.lowercased()
        return id == "com.apple" || id.hasPrefix("com.apple.") || id == Bundle.main.bundleIdentifier?.lowercased()
    }

    /// A value from Info.plist that is safe to use as one path component.
    static func isSafeComponent(_ s: String) -> Bool {
        !s.isEmpty && s != "." && s != ".." && !s.contains("/") && !s.contains(":") && !s.contains("\0")
    }

    /// Letters, digits, dots and hyphens, the characters bundle identifiers are made of.
    static func isWellFormedBundleID(_ id: String) -> Bool {
        isSafeComponent(id) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
    }

    /// `com.vendor.app` or longer. Shorter identifiers (`com`, `com.google`) are vendor prefixes:
    /// matching `<id>.*` with them would sweep up other apps' files, so they only match exactly.
    static func allowsPrefixMatching(_ id: String) -> Bool {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 3 && !parts.contains { $0.isEmpty }
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
            groups.append(ScanGroup(id: "app", title: String(localized: "Application"), detail: app.url.path,
                                    section: app.name, risk: .review, autoSelect: true, owners: [app.bundleID],
                                    icon: "shippingbox", tint: "pink", items: [bundle]))
        }
        let installed = installedApps(measureSizes: false)
        let others = installed.map(\.bundleID).filter { $0 != app.bundleID }
        // Info.plist is just a file: an app only vouches for its bundle identifier when a valid signature covers it,
        // and no other installed app claims the same identifier. Otherwise its files are listed but not preselected.
        let sharesID = installed.contains { $0.url != app.url && $0.bundleID.lowercased() == app.bundleID.lowercased() }
        let unverified: String? = sharesID
            ? String(localized: "Not preselected: another installed app uses the same identifier.")
            : CodeIntegrity.teamIdentifier(of: app.url) == nil
                ? String(localized: "Not preselected: this app isn't signed by an identified developer, so nothing proves these files are its own.")
                : nil
        let leftovers = leftovers(bundleID: app.bundleID, name: app.name, otherBundleIDs: others)
        // Data the knowledge base protects (profiles, vaults, unsynced files) is offered separately and never preselected.
        let (support, data) = (leftovers.filter { knowledgeBase.protectingApp(for: $0.url, home: home) == nil },
                               leftovers.filter { knowledgeBase.protectingApp(for: $0.url, home: home) != nil })
        let extra = knowledgeBaseFiles(bundleID: app.bundleID)
            .filter { url in !leftovers.contains { SafetyPolicy.isSameOrInside(url.standardizedFileURL.path, $0.url.path) } }
            .compactMap { DiskUsage.item(for: $0) }
        let supportItems = support + extra.filter { knowledgeBase.protectingApp(for: $0.url, home: home) == nil }
        let dataItems = data + extra.filter { knowledgeBase.protectingApp(for: $0.url, home: home) != nil }
        if !supportItems.isEmpty {
            groups.append(ScanGroup(id: "leftovers", title: String(localized: "Support files"),
                                    detail: unverified ?? String(localized: "Preferences, caches, containers and other files created by the app"),
                                    section: app.name, risk: .review, autoSelect: unverified == nil, owners: [app.bundleID],
                                    icon: "lock.shield", tint: "indigo", items: supportItems.sorted { $0.size > $1.size }))
        }
        if !dataItems.isEmpty {
            let why = knowledgeBase.app(forBundleID: app.bundleID).map { String(localized: String.LocalizationValue($0.why)) } ?? String(localized: "Data you may want to keep.")
            groups.append(ScanGroup(id: "app-data", title: String(localized: "Your data in \(app.name)"), detail: why,
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

    /// Files in `~/Library` that belong to `bundleID`. `otherBundleIDs` are the other installed apps: a
    /// prefix match that belongs to one of them (`com.vendor.app.beta` when removing `com.vendor.app`) is left alone.
    public func leftovers(bundleID: String, name: String, otherBundleIDs: [String] = []) -> [ScanItem] {
        guard Self.isWellFormedBundleID(bundleID) else { return [] }
        let lib = home.appendingPathComponent("Library")
        let prefixMatching = Self.allowsPrefixMatching(bundleID)
        var found: [(url: URL, folder: URL, prefix: Bool)] = []

        /// Looks for `leaf` directly inside `~/Library/<folder>`.
        func add(_ folder: String, _ leaf: String, prefix: Bool = false) {
            guard !prefix || prefixMatching else { return }
            let parent = lib.appendingPathComponent(folder)
            found += PathPattern.expand(parent.appendingPathComponent(leaf).path, home: home).map { ($0, parent, prefix) }
        }
        func escaped(_ s: String) -> String {
            s.replacingOccurrences(of: "[", with: "[[]").replacingOccurrences(of: "*", with: "[*]").replacingOccurrences(of: "?", with: "[?]")
        }
        let e = escaped(bundleID)

        // Keyed by bundle identifier.
        for folder in ["Application Support", "Caches", "HTTPStorages", "WebKit", "Containers", "Application Scripts", "Logs"] {
            add(folder, e)
            add(folder, "\(e).*", prefix: true)
        }
        add("Preferences", "\(e).plist")
        add("Preferences", "\(e).*.plist", prefix: true)
        add("Preferences/ByHost", "\(e).*.plist", prefix: true)
        add("Saved Application State", "\(e).savedState")
        add("HTTPStorages", "\(e).binarycookies")
        add("Cookies", "\(e).binarycookies")
        add("LaunchAgents", "\(e).plist")
        add("LaunchAgents", "\(e).*.plist", prefix: true)
        add("Group Containers", "*.\(e)", prefix: true)
        add("Group Containers", "*.\(e).*", prefix: true)

        // Keyed by app name, only in folders where apps conventionally use their name.
        if name.count >= 3, Self.isSafeComponent(name) {
            for folder in ["Application Support", "Caches", "Logs"] {
                add(folder, escaped(name))
            }
        }

        let id = bundleID.lowercased()
        let extending = otherBundleIDs.map { $0.lowercased() }.filter { $0.hasPrefix(id + ".") }
        func belongsToAnotherApp(_ leaf: String) -> Bool {
            let leaf = leaf.lowercased()
            return extending.contains { leaf == $0 || leaf.hasPrefix($0 + ".") || leaf.hasSuffix("." + $0) || leaf.contains("." + $0 + ".") }
        }

        var seen = Set<String>()
        return found
            .filter { match in
                // Directly inside the folder it was looked up in, whatever the identifier or name said.
                SafetyPolicy.key(match.url.standardizedFileURL.deletingLastPathComponent().path)
                    == SafetyPolicy.key(match.folder.standardizedFileURL.path)
            }
            .filter { !$0.prefix || !belongsToAnotherApp($0.url.lastPathComponent) }
            .map(\.url)
            .filter { seen.insert(SafetyPolicy.key($0.standardizedFileURL.path)).inserted && policy.isAllowed($0) }
            .compactMap { DiskUsage.item(for: $0) }
            .sorted { $0.size > $1.size }
    }
}
