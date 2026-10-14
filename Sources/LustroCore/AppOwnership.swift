import Foundation

/// A running application, as seen by the app layer (kept AppKit-free so the core stays testable).
public struct RunningApp: Hashable, Sendable {
    public let bundleID: String
    public let name: String
    public let pid: Int32

    public init(bundleID: String, name: String, pid: Int32) {
        self.bundleID = bundleID
        self.name = name
        self.pid = pid
    }
}

/// Works out which running apps a file belongs to, so their files are not removed
/// while they are open. Errs on the side of matching: a false match only costs a prompt.
public struct AppOwnership: Sendable {
    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Library folders whose first-level entries are named after the owning app.
    static let ownerKeyedFolders = [
        "Library/Caches", "Library/Application Support", "Library/Containers", "Library/Group Containers",
        "Library/HTTPStorages", "Library/WebKit", "Library/Logs", "Library/Saved Application State",
        "Library/Preferences",
    ]

    /// Folder names too generic to identify an app on their own.
    static let genericNames: Set<String> = ["com", "org", "net", "io", "app", "apple", "cache", "caches",
                                            "logs", "data", "helper", "shared", "default", "library"]

    /// Running apps that own `url`. `explicitOwners` are bundle IDs declared by the rule that found the item.
    public func runningOwners(of url: URL, explicitOwners: [String] = [], running: [RunningApp]) -> [RunningApp] {
        let key = ownerKey(for: url)
        return running.filter { app in
            explicitOwners.contains { Self.sameFamily(app.bundleID, $0) }
                || key.map { Self.matches(key: $0, app: app) } == true
        }
    }

    /// First path component below an owner-keyed Library folder, e.g. `com.google.Chrome` or `Firefox`.
    public func ownerKey(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        for folder in Self.ownerKeyedFolders {
            let root = home.appendingPathComponent(folder).path + "/"
            guard path.hasPrefix(root) else { continue }
            let rest = path.dropFirst(root.count)
            var key = String(rest.split(separator: "/").first ?? "")
            // Group containers, and some helpers' containers, are prefixed with a team ID: "ABCDE12345.com.example.app".
            if folder == "Library/Group Containers" || folder == "Library/Containers", Self.startsWithTeamID(key),
               let dot = key.firstIndex(of: ".") {
                key = String(key[key.index(after: dot)...])
            }
            for suffix in [".plist", ".savedState", ".binarycookies"] where key.hasSuffix(suffix) {
                key = String(key.dropLast(suffix.count))
            }
            return key.isEmpty ? nil : key
        }
        return nil
    }

    /// Whether `name` starts with a team ID (ten capital letters or digits) and a dot.
    static func startsWithTeamID(_ name: String) -> Bool {
        guard let dot = name.firstIndex(of: ".") else { return false }
        let team = name[..<dot]
        return team.count == 10 && team.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    static func matches(key: String, app: RunningApp) -> Bool {
        let lowerKey = key.lowercased()
        if key.contains(".") {
            // Bundle-ID style folder: same app, a helper of it (com.app.Helper), or vice versa.
            return sameFamily(app.bundleID, key)
        }
        guard lowerKey.count >= 3, !genericNames.contains(lowerKey) else { return false }
        // Name-style folder ("Firefox", "Google"): match the app name or a bundle-ID component.
        if app.name.lowercased() == lowerKey || app.name.lowercased().hasPrefix(lowerKey + " ") { return true }
        let components = app.bundleID.lowercased().split(separator: ".").dropFirst() // skip "com"/"org"
        return components.contains { $0 == lowerKey }
    }

    static func sameFamily(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased(), y = b.lowercased()
        return x == y || x.hasPrefix(y + ".") || y.hasPrefix(x + ".")
    }
}
