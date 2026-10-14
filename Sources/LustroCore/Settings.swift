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
        var info = stat()
        // Only a real folder of the user's is moved into place, never a link planted under the old name.
        guard lstat(old.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              lstat(new.path, &info) != 0, StateDirectory.isSafe(support, home: home) else { return }
        try? FileManager.default.moveItem(at: old, to: new)
    }

    public static func load(from url: URL = fileURL) -> LustroSettings {
        guard StateDirectory.isSafe(url.deletingLastPathComponent()),
              let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(LustroSettings.self, from: data) else { return LustroSettings() }
        return settings
    }

    public func save(to url: URL = fileURL) throws {
        try StateDirectory.prepare(url.deletingLastPathComponent())
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

/// Lustro's own folder in Application Support. Another program in the account could replace it, or a
/// folder above it, with a link into a protected location that Lustro would then read and write with
/// its permissions. Every read and write of settings and history checks it first.
public enum StateDirectory {
    public struct Unsafe: Error, CustomStringConvertible {
        public let path: String
        public var description: String { String(localized: "Lustro's data folder is not a regular folder of yours: \(path)") }
    }

    /// Each folder from the home folder down to `dir` that exists is a real folder (not a link) owned by
    /// the user. Outside the home folder (tests) only `dir` itself is checked.
    public static func isSafe(_ dir: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        for folder in chain(to: dir, home: home) {
            var info = stat()
            guard lstat(folder.path, &info) == 0 else { continue }
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { return false }
        }
        return true
    }

    /// Creates any missing folders (private to the user) after checking the ones that exist.
    public static func prepare(_ dir: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        for folder in chain(to: dir, home: home) {
            var info = stat()
            if lstat(folder.path, &info) != 0 {
                guard mkdir(folder.path, 0o700) == 0 || errno == EEXIST else { throw Unsafe(path: folder.path) }
                guard lstat(folder.path, &info) == 0 else { throw Unsafe(path: folder.path) }
            }
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { throw Unsafe(path: folder.path) }
        }
    }

    private static func chain(to dir: URL, home: URL) -> [URL] {
        let dir = dir.standardizedFileURL, home = home.standardizedFileURL
        let homeParts = home.pathComponents, dirParts = dir.pathComponents
        guard dirParts.count > homeParts.count, Array(dirParts.prefix(homeParts.count)) == homeParts else { return [dir] }
        return (homeParts.count..<dirParts.count).map { end in
            dirParts[homeParts.count...end].reduce(home) { $0.appendingPathComponent($1) }
        }
    }
}
