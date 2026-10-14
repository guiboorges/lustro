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

/// Light or dark, or whatever macOS uses.
public enum Appearance: String, Codable, Sendable, CaseIterable {
    case system, light, dark
}

/// The interface language. `system` follows macOS; Portuguese picks Brazil or Portugal from the Mac's list.
public enum AppLanguage: String, Codable, Sendable, CaseIterable {
    case system, english, portuguese

    /// Value for the app's `AppleLanguages` default, or nil to follow macOS.
    public func appleLanguages(preferred: [String] = Locale.preferredLanguages) -> [String]? {
        switch self {
        case .system: nil
        case .english: ["en"]
        case .portuguese: [preferred.contains { $0.hasPrefix("pt-PT") } ? "pt-PT" : "pt-BR"]
        }
    }
}

/// User settings, persisted as JSON in `~/Library/Application Support/Lustro/settings.json`.
public struct LustroSettings: Codable, Equatable, Sendable {
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
    public var appearance: Appearance = .system
    public var language: AppLanguage = .system

    public init() {}

    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Lustro/settings.json")
    }

    /// Moves settings and history saved under the project's former name ("Limpo").
    public static func migrateFromPreviousName(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let support = home.appendingPathComponent("Library/Application Support")
        let old = support.appendingPathComponent("Limpo")
        let new = support.appendingPathComponent("Lustro")
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        try? fm.moveItem(at: old, to: new)
    }

    public static func load(from url: URL = fileURL) -> LustroSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(LustroSettings.self, from: data) else { return LustroSettings() }
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
extension LustroSettings {
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
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? appearance
        language = try c.decodeIfPresent(AppLanguage.self, forKey: .language) ?? language
    }
}
