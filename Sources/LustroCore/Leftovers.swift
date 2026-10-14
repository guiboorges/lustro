import Foundation

/// Finds files left behind by apps that are no longer installed (decision engine, phase 2).
///
/// Only exact bundle-identifier names are considered (`com.vendor.App`, at least three parts), in the
/// folders where macOS and apps key data by bundle ID. A candidate must have no installed owner, no
/// knowledge-base protection, and no changes for `minimumAge`: something still writing to it is in use.
/// Results are never preselected.
public struct LeftoverScanner: Sendable {
    /// Whether an app (or a helper of one) with this bundle ID is installed or running.
    public typealias OwnerCheck = @Sendable (String) -> Bool

    public let home: URL
    public let policy: SafetyPolicy
    public let knowledgeBase: AppKnowledgeBase
    public let hasFullDiskAccess: Bool
    public let minimumAge: TimeInterval
    public let now: Date
    private let isOwned: OwnerCheck

    public static let groupID = "leftovers"

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, policy: SafetyPolicy = SafetyPolicy(),
                knowledgeBase: AppKnowledgeBase = .bundled(), hasFullDiskAccess: Bool = false,
                minimumAge: TimeInterval = 30 * 86_400, now: Date = Date(), isOwned: @escaping OwnerCheck) {
        self.home = home
        self.policy = policy
        self.knowledgeBase = knowledgeBase
        self.hasFullDiskAccess = hasFullDiskAccess
        self.minimumAge = minimumAge
        self.now = now
        self.isOwned = isOwned
    }

    /// Folders keyed by bundle ID, with the suffix each entry carries. Containers need Full Disk Access
    /// (otherwise macOS asks about every other app's data).
    var locations: [(folder: String, suffix: String)] {
        var list = [("Application Support", ""), ("Preferences", ".plist"), ("Saved Application State", ".savedState"),
                    ("HTTPStorages", ""), ("HTTPStorages", ".binarycookies"), ("WebKit", ""), ("Application Scripts", "")]
        if hasFullDiskAccess { list.append(("Containers", "")) }
        return list
    }

    public func scan() -> ScanGroup? {
        let library = home.appendingPathComponent("Library")
        var items: [ScanItem] = []
        var seen = Set<String>()
        let knownSuffixes = Set(locations.map(\.suffix).filter { !$0.isEmpty })
        for (folder, suffix) in locations {
            let base = library.appendingPathComponent(folder)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
            for name in names where name.hasSuffix(suffix) {
                // A bare-name pass must not pick up `x.binarycookies` as if `binarycookies` were part of an ID.
                if suffix.isEmpty, knownSuffixes.contains(where: { name.hasSuffix($0) }) { continue }
                guard seen.insert("\(folder)/\(name)").inserted else { continue }
                let id = String(name.dropLast(suffix.count))
                guard Self.looksLikeBundleID(id), !Self.isSystemID(id), !isOwned(id) else { continue }
                let url = base.appendingPathComponent(name)
                guard policy.isAllowed(url), knowledgeBase.protectingApp(for: url, home: home) == nil else { continue }
                if let latest = DiskUsage.latestModification(in: url), now.timeIntervalSince(latest) < minimumAge { continue }
                guard let item = DiskUsage.item(for: url), item.size > 0 else { continue }
                let days = item.lastModified.map { Int(now.timeIntervalSince($0) / 86_400) }
                items.append(item.with(note: id, evidence: "No installed app has the ID \(id)"
                                       + (days.map { " · untouched for \($0) days" } ?? "")))
            }
        }
        guard !items.isEmpty else { return nil }
        return ScanGroup(id: Self.groupID, title: "Leftovers of removed apps",
                         detail: "Settings and data of apps that are no longer installed",
                         section: "System", risk: .review, autoSelect: false,
                         icon: "shippingbox.and.arrow.backward", tint: "orange",
                         items: items.sorted { $0.size > $1.size })
    }

    /// `com.vendor.App`, `io.github.user.tool`: three or more dot-separated parts, no spaces.
    public static func looksLikeBundleID(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 3 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
    }

    /// Apple's own IDs, Lustro, and IDs that SDKs and system services write on behalf of other apps.
    static let notAppPrefixes = ["com.apple.", "io.github.guiboorges.lustro", "com.firebase.", "com.google.gmp.",
                                 "com.google.firebase.", "com.segment.", "com.crashlytics", "io.sentry", "com.microsoft.appcenter",
                                 "com.amplitude.", "com.mixpanel.", "org.cups.", "com.bugsnag.", "com.heap.", "io.fabric."]

    static func isSystemID(_ id: String) -> Bool {
        let lower = normalized(id)
        return notAppPrefixes.contains { lower.hasPrefix($0.lowercased()) }
    }

    /// `group.com.vendor.App` → `com.vendor.app`.
    static func normalized(_ id: String) -> String {
        let lower = id.lowercased()
        return lower.hasPrefix("group.") ? String(lower.dropFirst(6)) : lower
    }

    /// Conservative ownership: an ID counts as owned when
    /// - it is, extends or is extended by a known ID (`com.vendor.App`, `.helper`, `com.vendor.app.shared` …),
    /// - any known app comes from the same vendor (`com.adobe.*` while Creative Cloud is installed: vendors share
    ///   files between their apps, and guessing wrong would break the installed ones), or
    /// - `lookup` (LaunchServices in the app) finds an app for it or for one of its prefixes.
    /// `knownIDs` should hold installed and running apps and the labels of working launch agents.
    public static func ownerCheck(knownIDs: [String], lookup: @escaping @Sendable (String) -> Bool = { _ in false }) -> OwnerCheck {
        let ids = Set(knownIDs.map(normalized))
        let vendors = Set(ids.compactMap(vendor))
        return { candidate in
            let id = normalized(candidate)
            if ids.contains(id) || ids.contains(where: { id.hasPrefix($0 + ".") || $0.hasPrefix(id + ".") }) { return true }
            if let vendor = vendor(of: id), vendors.contains(vendor) { return true }
            var parts = candidate.split(separator: ".").map(String.init)
            if parts.first?.lowercased() == "group" { parts.removeFirst() }
            while parts.count >= 3 {
                if lookup(parts.joined(separator: ".")) { return true }
                parts.removeLast()
            }
            return false
        }
    }

    /// `com.adobe.Photoshop` → `com.adobe`. Nil for IDs too short to tell.
    static func vendor(of id: String) -> String? {
        let parts = id.split(separator: ".")
        return parts.count >= 3 ? parts.prefix(2).joined(separator: ".") : nil
    }

    /// Owner check from installed app IDs only (no LaunchServices).
    public static func installedOwnerCheck(installedIDs: [String]) -> OwnerCheck {
        ownerCheck(knownIDs: installedIDs)
    }
}

/// Files held open by running processes (phase 4): removing them could break what's using them.
public enum OpenFiles {
    public struct Holder: Sendable, Hashable {
        public let pid: Int32
        public let name: String
    }

    /// For each item, the processes (of this user) with a file open at or inside it. One pass over all processes.
    public static func holders(of urls: [URL]) -> [URL: [Holder]] {
        guard !urls.isEmpty else { return [:] }
        // The kernel reports real paths (/private/var/…). Foundation's resolvingSymlinksInPath strips
        // /private again, so ask realpath(3).
        let targets = urls.map { url in
            (url, realpath(url.path, nil).map { pointer in defer { free(pointer) }; return String(cString: pointer) } ?? url.path)
        }
        var result: [URL: Set<Holder>] = [:]
        let uid = getuid()
        let own = getpid()
        for pid in ProcessMonitor.allPIDs() where pid > 0 && pid != own {
            guard let info = ProcessMonitor.bsdInfo(pid), info.pbi_uid == uid else { continue }
            let paths = openPaths(pid)
            guard !paths.isEmpty else { continue }
            for (url, root) in targets where paths.contains(where: { SafetyPolicy.isSameOrInside($0, root) }) {
                result[url, default: []].insert(Holder(pid: pid, name: ProcessMonitor.name(pid) ?? "pid \(pid)"))
            }
        }
        return result.mapValues { Array($0).sorted { $0.name < $1.name } }
    }

    static func openPaths(_ pid: Int32) -> [String] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 8)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard used > 0 else { return [] }
        var paths: [String] = []
        for fd in fds.prefix(Int(used) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if !path.isEmpty { paths.append(path) }
        }
        return paths
    }
}

/// Time Machine exclusions for folders that can be rebuilt (node_modules, target, .build…).
/// Uses the same sticky exclusion as `tmutil addexclusion`; no administrator rights needed.
public enum BackupExclusion {
    public static func isExcluded(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true
    }

    /// Returns the URLs that couldn't be changed.
    @discardableResult
    public static func setExcluded(_ excluded: Bool, _ urls: [URL]) -> [URL] {
        urls.filter { url in
            var copy = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = excluded
            return (try? copy.setResourceValues(values)) == nil
        }
    }
}
