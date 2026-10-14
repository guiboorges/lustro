import Foundation

/// Per-app knowledge (`apps.json`): which of an app's files are disposable and which must never be
/// suggested for removal. `never` entries override every rule; `files` entries are the exceptions
/// inside them (e.g. a cache folder inside a browser profile).
public struct AppKnowledgeBase: Codable, Sendable {
    public struct App: Codable, Sendable {
        public let bundleIDs: [String]
        public let name: String
        public let files: [Entry]?
        public let never: [String]?
        /// Why the entries are what they are. Required for contributions.
        public let why: String
    }

    public struct Entry: Codable, Sendable {
        public let path: String
        /// cache, log, temporary, appData…
        public let kind: String
    }

    public let version: Int
    public let apps: [App]

    public init(version: Int = 1, apps: [App]) {
        self.version = version
        self.apps = apps
    }

    public static func bundled() -> AppKnowledgeBase {
        guard let url = RuleCatalog.resourceBundle.url(forResource: "apps", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let base = try? JSONDecoder().decode(AppKnowledgeBase.self, from: data) else {
            return AppKnowledgeBase(apps: [])
        }
        return base
    }

    /// The app whose protected data `url` is, or contains (a parent folder would sweep it up too),
    /// unless one of the app's `files` entries allows that exact spot.
    public func protectingApp(for url: URL, home: URL) -> App? {
        let path = url.standardizedFileURL.path
        for app in apps {
            let never = app.never ?? []
            if never.contains(where: { PathPattern.covers($0, path: path, home: home) }) {
                if app.files?.contains(where: { PathPattern.covers($0.path, path: path, home: home) }) == true { continue }
                return app
            }
            if never.contains(where: { PathPattern.isAncestor(path, of: $0, home: home) }) { return app }
        }
        return nil
    }

    public func app(forBundleID id: String) -> App? {
        apps.first { $0.bundleIDs.contains(id) }
    }

    /// Problems that would make an entry unsafe or useless. Empty when the file is valid (checked in CI).
    public func validationErrors() -> [String] {
        var errors: [String] = []
        var seen = Set<String>()
        for app in apps {
            if app.bundleIDs.isEmpty { errors.append("\(app.name): no bundleIDs") }
            for id in app.bundleIDs where !seen.insert(id).inserted { errors.append("\(id): listed twice") }
            if app.why.trimmingCharacters(in: .whitespaces).count < 10 { errors.append("\(app.name): explain why") }
            if (app.files ?? []).isEmpty && (app.never ?? []).isEmpty { errors.append("\(app.name): no entries") }
            for path in (app.files ?? []).map(\.path) + (app.never ?? []) {
                if !path.hasPrefix("~/") { errors.append("\(app.name): \(path) must start with ~/") }
                if path.contains("**") { errors.append("\(app.name): \(path) uses **") }
                if path == "~/" || path == "~/Library" || path.hasSuffix("/*") && path.split(separator: "/").count <= 3 {
                    errors.append("\(app.name): \(path) is too broad")
                }
            }
        }
        return errors
    }
}

extension PathPattern {
    /// True when `path` is a folder above whatever `pattern` matches, e.g. `~/Library/Application Support/Code`
    /// is an ancestor of `~/Library/Application Support/Code/User`.
    public static func isAncestor(_ path: String, of pattern: String, home: URL) -> Bool {
        var expanded = pattern
        if expanded.hasPrefix("~/") { expanded = home.path + String(expanded.dropFirst(1)) }
        let patternParts = expanded.split(separator: "/").map(String.init)
        let pathParts = path.split(separator: "/").map(String.init)
        guard patternParts.count > pathParts.count else { return false }
        return zip(patternParts, pathParts).allSatisfy(segmentMatches)
    }

    /// True when `path` is a match of `pattern` or lies inside one. Matches segment by segment, so
    /// `~/Library/Application Support/Google/Chrome/*/GPUCache` covers `…/Chrome/Default/GPUCache/data_1`.
    public static func covers(_ pattern: String, path: String, home: URL) -> Bool {
        var expanded = pattern
        if expanded.hasPrefix("~/") { expanded = home.path + String(expanded.dropFirst(1)) }
        let patternParts = expanded.split(separator: "/").map(String.init)
        let pathParts = path.split(separator: "/").map(String.init)
        guard pathParts.count >= patternParts.count else { return false }
        return zip(patternParts, pathParts).allSatisfy(segmentMatches)
    }

    /// Compares one segment the way APFS does by default: ignoring case and Unicode normalisation.
    static func segmentMatches(_ pattern: String, _ name: String) -> Bool {
        let p = pattern.precomposedStringWithCanonicalMapping, n = name.precomposedStringWithCanonicalMapping
        return hasWildcard(p) ? fnmatch(p, n, FNM_CASEFOLD) == 0 : p.caseInsensitiveCompare(n) == .orderedSame
    }
}
