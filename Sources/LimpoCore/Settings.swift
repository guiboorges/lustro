import Foundation

/// How review lists start out.
public enum PreselectionMode: String, Codable, Sendable, CaseIterable {
    /// Nothing selected; the user picks everything.
    case off
    /// Each category's own default (safe items yes, review items no).
    case smart
    /// Every safe and review item; caution items are still never preselected.
    case allSafe
}

/// User settings, persisted as JSON in `~/Library/Application Support/Limpo/settings.json`.
public struct LimpoSettings: Codable, Equatable, Sendable {
    public var removalMode: RemovalMode = .trash
    public var dryRun: Bool = false
    public var reopenAppsAfterCleaning: Bool = true
    public var preselection: PreselectionMode = .smart
    public var keepNewestBackup: Bool = true
    /// Paths excluded from every scan and removal.
    public var ignoredPaths: [String] = []
    /// Folders searched for project artifacts. Empty means the default roots.
    public var projectRoots: [String] = []
    public var inactiveDaysForAutoSelect: Int = 30
    /// Junk category IDs the user turned off.
    public var disabledCategories: [String] = []

    public init() {}

    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Limpo/settings.json")
    }

    public static func load(from url: URL = fileURL) -> LimpoSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(LimpoSettings.self, from: data) else { return LimpoSettings() }
        return settings
    }

    public func save(to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public var ignoredURLs: [URL] { ignoredPaths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } }

    public func policy(extraAllowedRoots: [URL] = []) -> SafetyPolicy {
        SafetyPolicy(extraAllowedRoots: extraAllowedRoots, ignoredPaths: ignoredURLs)
    }

    public var resolvedProjectRoots: [URL] {
        projectRoots.isEmpty
            ? ProjectArtifactScanner.defaultRoots()
            : projectRoots.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }
}

// Tolerate settings files written by older versions that lack newer keys.
extension LimpoSettings {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        removalMode = try c.decodeIfPresent(RemovalMode.self, forKey: .removalMode) ?? removalMode
        dryRun = try c.decodeIfPresent(Bool.self, forKey: .dryRun) ?? dryRun
        reopenAppsAfterCleaning = try c.decodeIfPresent(Bool.self, forKey: .reopenAppsAfterCleaning) ?? reopenAppsAfterCleaning
        preselection = try c.decodeIfPresent(PreselectionMode.self, forKey: .preselection) ?? preselection
        keepNewestBackup = try c.decodeIfPresent(Bool.self, forKey: .keepNewestBackup) ?? keepNewestBackup
        ignoredPaths = try c.decodeIfPresent([String].self, forKey: .ignoredPaths) ?? ignoredPaths
        projectRoots = try c.decodeIfPresent([String].self, forKey: .projectRoots) ?? projectRoots
        inactiveDaysForAutoSelect = try c.decodeIfPresent(Int.self, forKey: .inactiveDaysForAutoSelect) ?? inactiveDaysForAutoSelect
        disabledCategories = try c.decodeIfPresent([String].self, forKey: .disabledCategories) ?? disabledCategories
    }
}
