import Foundation

/// Finds removable junk described by a `RuleCatalog`.
public struct JunkScanner: Sendable {
    public let catalog: RuleCatalog
    public let policy: SafetyPolicy
    public let now: Date
    public let hasFullDiskAccess: Bool
    public let disabledCategories: Set<String>
    public let keepNewestBackup: Bool

    public init(catalog: RuleCatalog, policy: SafetyPolicy = SafetyPolicy(), hasFullDiskAccess: Bool = false,
                disabledCategories: Set<String> = [], keepNewestBackup: Bool = true, now: Date = Date()) {
        self.catalog = catalog
        self.policy = policy
        self.hasFullDiskAccess = hasFullDiskAccess
        self.disabledCategories = disabledCategories
        self.keepNewestBackup = keepNewestBackup
        self.now = now
    }

    /// Categories that will run with the current settings and permissions.
    public var activeCategories: [JunkCategory] {
        catalog.categories.filter { category in
            !disabledCategories.contains(category.id)
                && (hasFullDiskAccess || category.requiresFullDiskAccess != true)
        }
    }

    public func scan(progress: ProgressHandler? = nil) async -> [ScanGroup] {
        let categories = activeCategories
        var groups: [ScanGroup] = []
        // Earlier (more specific) categories claim paths first, so nothing is listed twice.
        var claimed: [String] = []
        for (index, category) in categories.enumerated() {
            if Task.isCancelled { break }
            progress?(ScanProgress(message: category.title, fraction: Double(index) / Double(max(categories.count, 1))))
            let (items, candidates) = scan(category, excluding: claimed)
            // Claim every candidate, including ones skipped as too recent, so a broader
            // category (e.g. all of ~/Library/Caches) cannot sweep them up anyway.
            claimed += candidates
            if !items.isEmpty {
                groups.append(ScanGroup(
                    id: category.id, title: category.title, detail: category.detail,
                    section: category.section, risk: category.risk,
                    autoSelect: category.autoSelect, owners: category.owners ?? [],
                    icon: category.icon, tint: category.tint,
                    items: items.sorted { $0.size > $1.size }
                ))
            }
        }
        progress?(ScanProgress(message: "Done", fraction: 1))
        return groups
    }

    func scan(_ category: JunkCategory, excluding claimed: [String] = []) -> (items: [ScanItem], candidates: [String]) {
        var seen = Set<String>()
        var urls: [URL] = []
        var matchedBy: [String: String] = [:]
        for target in category.targets {
            for url in PathPattern.expand(target.path, home: policy.home) {
                let name = url.lastPathComponent
                if target.exclude?.contains(where: { PathPattern.matches(name, $0) }) == true { continue }
                let path = url.standardizedFileURL.path
                if claimed.contains(where: { SafetyPolicy.isSameOrInside(path, $0) || SafetyPolicy.isStrictlyInside($0, path) }) { continue }
                guard policy.isAllowed(url), seen.insert(path).inserted else { continue }
                urls.append(url)
                matchedBy[path] = target.path
            }
        }
        // Drop items nested inside another selected item so nothing is counted twice.
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        urls.removeAll { url in
            paths.contains { SafetyPolicy.isStrictlyInside(url.standardizedFileURL.path, $0) }
        }

        let items = urls.compactMap { url -> ScanItem? in
            if Task.isCancelled { return nil }
            if let hours = category.minAgeHours, hours > 0,
               let latest = DiskUsage.latestModification(in: url),
               now.timeIntervalSince(latest) < hours * 3600 {
                return nil
            }
            guard let item = DiskUsage.item(for: url), item.size > 0 else { return nil }
            let rule = matchedBy[url.standardizedFileURL.path].map { "Listed by rule \(category.id): \($0)" }
            return item.with(evidence: rule)
        }
        if category.keepNewestPerDevice == true {
            return (DeviceBackups.label(items, keepNewest: keepNewestBackup), Array(seen))
        }
        return (items, Array(seen))
    }
}
