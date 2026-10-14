import Foundation

/// The cleaning rule catalog, loaded from `rules.json`.
/// Keeping rules in data (not code) lets contributors add apps without touching Swift.
public struct RuleCatalog: Codable, Sendable {
    public let version: Int
    public let categories: [JunkCategory]

    public static func bundled() throws -> RuleCatalog {
        guard let url = resourceBundle.url(forResource: "rules", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try load(from: url)
    }

    /// Looks inside an app's `Contents/Resources` first, where `build-app.sh` places the
    /// SwiftPM resource bundle, then falls back to SwiftPM's own lookup for `swift run`/tests.
    static var resourceBundle: Bundle {
        let name = "Lustro_LustroCore.bundle"
        for base in [Bundle.main.resourceURL, Bundle.main.bundleURL] {
            if let base, let bundle = Bundle(url: base.appendingPathComponent(name)) { return bundle }
        }
        return Bundle.module
    }

    public static func load(from url: URL) throws -> RuleCatalog {
        try JSONDecoder().decode(RuleCatalog.self, from: Data(contentsOf: url))
    }
}

public struct JunkCategory: Codable, Sendable, Identifiable {
    public let id: String
    /// Grouping shown in the UI, e.g. "System", "Developer tools", "AI tools".
    public let section: String
    public let title: String
    public let detail: String
    public let risk: RiskLevel
    public let autoSelect: Bool
    /// Items modified more recently than this are skipped (likely in use).
    public let minAgeHours: Double?
    /// Skipped unless the app has Full Disk Access (avoids a flood of macOS privacy prompts).
    public let requiresFullDiskAccess: Bool?
    /// Bundle IDs of the apps these files belong to; their files are held back while they run.
    public let owners: [String]?
    /// SF Symbol name and accent colour for the category tile.
    public let icon: String?
    public let tint: String?
    /// For device backups: hide the most recent backup of each device.
    public let keepNewestPerDevice: Bool?
    public let targets: [JunkTarget]
}

public struct JunkTarget: Codable, Sendable {
    /// Glob pattern for the items to remove, e.g. `~/Library/Caches/*`.
    public let path: String
    /// Name patterns (last path component) that are never removed.
    public let exclude: [String]?
}
