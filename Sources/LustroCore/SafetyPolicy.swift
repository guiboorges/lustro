import Foundation

/// Why a path was refused.
public enum SafetyViolation: Error, Equatable, Sendable, CustomStringConvertible {
    case notAbsolute(String)
    case protectedPath(String)
    case insideDeniedLocation(String)
    case outsideAllowedRoots(String)
    case ignoredByUser(String)
    case notOwnedByUser(String)
    case missing(String)
    case systemProtected(String)
    case cloudPlaceholder(String)
    case redirected(String)

    public var description: String {
        switch self {
        case .notAbsolute(let p): String(localized: "Path is not absolute: \(p)")
        case .protectedPath(let p): String(localized: "Protected location, never removed: \(p)")
        case .insideDeniedLocation(let p): String(localized: "Inside a location Lustro never touches: \(p)")
        case .outsideAllowedRoots(let p): String(localized: "Outside the folders Lustro is allowed to clean: \(p)")
        case .ignoredByUser(let p): String(localized: "On your ignore list: \(p)")
        case .notOwnedByUser(let p): String(localized: "Not owned by you: \(p)")
        case .missing(let p): String(localized: "No longer exists: \(p)")
        case .systemProtected(let p): String(localized: "Protected by macOS (SIP, restricted or locked): \(p)")
        case .cloudPlaceholder(let p): String(localized: "Only in iCloud, not on this Mac: \(p)")
        case .redirected(let p): String(localized: "Reached through a link that points somewhere else: \(p)")
        }
    }
}

/// Decides whether a path may be removed. Every removal goes through `validate`
/// immediately before touching the file system, so a path that became unsafe
/// after scanning (e.g. replaced by a symlink) is still refused.
public struct SafetyPolicy: Sendable {
    public let home: URL
    /// Extra roots allowed for this operation (e.g. `/Applications` for the uninstaller).
    public let extraAllowedRoots: [URL]
    public let ignoredPaths: [URL]
    /// Each allowed root as the caller wrote it and as it resolves, in `key` form.
    private let roots: [Root]

    struct Root: Sendable {
        let lexical: String
        let real: String
        /// Shared folders where only the current user's own files may go.
        let ownedOnly: Bool
    }

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                extraAllowedRoots: [URL] = [],
                ignoredPaths: [URL] = []) {
        self.home = home.standardizedFileURL.resolvingSymlinksInPath()
        self.extraAllowedRoots = extraAllowedRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        self.ignoredPaths = ignoredPaths.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        let given = ([home] + extraAllowedRoots).map(\.standardizedFileURL)
        roots = given.map { Root(lexical: Self.key($0.path), real: Self.key($0.resolvingSymlinksInPath().path), ownedOnly: false) }
            + Self.userOwnedTempRoots.map { Root(lexical: Self.key($0), real: Self.key($0), ownedOnly: true) }
    }

    /// Shared temporary directories where only files owned by the current user may be removed.
    static let userOwnedTempRoots = ["/private/tmp", "/private/var/tmp"]

    /// The form paths are compared in. APFS ignores case and Unicode normalisation by default, and
    /// Foundation drops the `/private` prefix when it resolves `/private/var` or `/private/tmp`,
    /// so `~/Library/Application Support/LUSTRO` must count as the protected `…/Lustro`.
    static func key(_ path: String) -> String {
        var p = path.precomposedStringWithCanonicalMapping.lowercased()
        for alias in ["/private/var", "/private/tmp", "/private/etc"] where p == alias || p.hasPrefix(alias + "/") {
            p.removeFirst("/private".count)
            break
        }
        return p
    }

    /// Paths that are never removed themselves, though their contents may be.
    var protectedExactPaths: Set<String> {
        let system = ["/", "/Applications", "/Library", "/System", "/Users", "/Volumes", "/bin", "/cores",
                      "/dev", "/etc", "/opt", "/private", "/private/tmp", "/private/var", "/private/var/tmp",
                      "/sbin", "/tmp", "/usr", "/var", "/Library/Caches", "/Library/Logs"]
        let homeRelative = ["", "Applications", "Desktop", "Developer", "Documents", "Downloads", "Movies",
                            "Music", "Pictures", "Public", "Sites", ".Trash", ".config", ".local", ".local/share",
                            ".cache", "Library", "Library/Application Support", "Library/Caches", "Library/Containers",
                            "Library/Group Containers", "Library/LaunchAgents", "Library/Logs", "Library/Preferences",
                            "Library/Saved Application State", "Library/HTTPStorages", "Library/WebKit",
                            "Library/Cookies", "Library/Developer", "Library/Developer/Xcode",
                            "Library/Mail", "Library/Messages", "Library/Safari", "Library/Fonts",
                            "Library/Audio", "Library/Audio/Plug-Ins", "Library/Autosave Information",
                            "Library/Application Scripts", "Library/Services", "Library/Spelling", "Library/Sounds"]
        var set = Set(system)
        for rel in homeRelative {
            set.insert(rel.isEmpty ? home.path : home.appendingPathComponent(rel).path)
        }
        return set
    }

    /// Locations whose contents are never touched, at any depth.
    var deniedPrefixes: [String] {
        let system = ["/System", "/bin", "/sbin", "/usr", "/dev", "/etc", "/private/etc", "/cores"]
        let homeRelative = ["Library/Keychains", ".ssh", ".gnupg", "Library/Mobile Documents",
                            "Library/CloudStorage", "Library/Mail", "Library/Messages", "Library/Safari",
                            "Library/Accounts", "Library/Photos", "Pictures/Photos Library.photoslibrary",
                            "Library/Application Support/Lustro"]
        return system + homeRelative.map { home.appendingPathComponent($0).path }
    }

    /// Throws if `url` must not be removed.
    public func validate(_ url: URL, fileManager: FileManager = .default) throws(SafetyViolation) {
        let raw = url.path
        guard raw.hasPrefix("/") else { throw .notAbsolute(raw) }

        let standardized = url.standardizedFileURL
        // Resolve symlinks in the *parent* only: removing a symlink itself is harmless,
        // but a symlinked parent could redirect us into a protected location.
        let parentReal = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
        let real = parentReal.appendingPathComponent(standardized.lastPathComponent)
        let lexicalKey = Self.key(standardized.path)
        let realKey = Self.key(real.path)

        let protected = Set(protectedExactPaths.map(Self.key))
        let denied = deniedPrefixes.map(Self.key)
        for candidate in Set([lexicalKey, realKey]) {
            if protected.contains(candidate) { throw .protectedPath(candidate == realKey ? real.path : standardized.path) }
            if let index = denied.firstIndex(where: { Self.isSameOrInside(candidate, $0) }) {
                throw .insideDeniedLocation(deniedPrefixes[index])
            }
            if ignoredPaths.contains(where: { Self.isSameOrInside(candidate, Self.key($0.path)) }) {
                throw .ignoredByUser(standardized.path)
            }
        }

        guard (try? real.checkResourceIsReachable()) == true
                || fileManager.fileExists(atPath: real.path)
                || isSymlink(real) else {
            throw .missing(real.path)
        }

        try checkFileFlags(real)

        try checkInsideRoots(standardized, real: real, ownership: true)
    }

    /// Checks a place an item is about to be put back to (History restore). Like `validate`, except that
    /// nothing has to exist there yet and the ignore list does not apply.
    public func validateDestination(_ url: URL) throws(SafetyViolation) {
        guard url.path.hasPrefix("/") else { throw .notAbsolute(url.path) }
        let standardized = url.standardizedFileURL
        // Resolve the deepest folder that exists; the rest will be created.
        var existing = standardized.deletingLastPathComponent()
        var missing: [String] = [standardized.lastPathComponent]
        var info = stat()
        while existing.path != "/", lstat(existing.path, &info) != 0 {
            missing.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        let real = missing.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }

        let protected = Set(protectedExactPaths.map(Self.key))
        let denied = deniedPrefixes.map(Self.key)
        for candidate in Set([Self.key(standardized.path), Self.key(real.path)]) {
            if protected.contains(candidate) { throw .protectedPath(standardized.path) }
            if let index = denied.firstIndex(where: { Self.isSameOrInside(candidate, $0) }) {
                throw .insideDeniedLocation(deniedPrefixes[index])
            }
        }
        try checkInsideRoots(standardized, real: real, ownership: false)
    }

    /// True when `url` is really in the user's Trash (or the user's Trash on another volume), not
    /// merely somewhere a path through a link makes it look like the Trash.
    public func isInTrash(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        let lexicalKey = Self.key(standardized.path)
        guard lexicalKey == Self.key(resolvedLocation(of: standardized).path) else { return false }
        if Self.isStrictlyInside(lexicalKey, Self.key(home.appendingPathComponent(".Trash").path)) { return true }
        // /Volumes/<name>/.Trashes/<uid>/…
        let parts = standardized.pathComponents
        return parts.count > 5 && parts[1] == "Volumes" && parts[3] == ".Trashes" && parts[4] == String(getuid())
    }

    /// The path must sit inside an allowed root as written, and resolve to the same place inside it.
    /// A symlink anywhere between the root and the item (a cache folder swapped for a link to
    /// ~/Documents, a symlinked ~/.Trash…) would make a harmless-looking path act on other data.
    private func checkInsideRoots(_ standardized: URL, real: URL, ownership: Bool) throws(SafetyViolation) {
        let lexicalKey = Self.key(standardized.path)
        let realKey = Self.key(real.path)
        for root in roots {
            for prefix in Set([root.lexical, root.real]) where Self.isStrictlyInside(lexicalKey, prefix) {
                guard realKey == root.real + lexicalKey.dropFirst(prefix.count) else { throw .redirected(standardized.path) }
                if ownership, root.ownedOnly, !isOwnedByCurrentUser(real) { throw .notOwnedByUser(real.path) }
                return
            }
        }
        throw .outsideAllowedRoots(real.path)
    }

    /// Where `url` really is once its parent folders are resolved, as `validate` sees it.
    public func resolvedLocation(of url: URL) -> URL {
        let standardized = url.standardizedFileURL
        return standardized.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(standardized.lastPathComponent)
    }

    public func isAllowed(_ url: URL) -> Bool {
        (try? validate(url)) != nil
    }

    // MARK: - Helpers

    static func isSameOrInside(_ path: String, _ root: String) -> Bool {
        path == root || isStrictlyInside(path, root)
    }

    static func isStrictlyInside(_ path: String, _ root: String) -> Bool {
        let base = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(base) && path.count > base.count
    }

    /// Flags that mean "leave this alone": system integrity protection, locked files and
    /// iCloud placeholders whose data is not on this Mac. Unlike some cleaners, Lustro never
    /// clears these flags to force a removal.
    static let lockedFlags = UInt32(UF_IMMUTABLE) | UInt32(SF_IMMUTABLE) | UInt32(SF_RESTRICTED) | UInt32(UF_APPEND) | UInt32(SF_APPEND)
    static let datalessFlag: UInt32 = 0x4000_0000 // SF_DATALESS

    private func checkFileFlags(_ url: URL) throws(SafetyViolation) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return }
        if info.st_flags & Self.lockedFlags != 0 { throw .systemProtected(url.path) }
        if info.st_flags & Self.datalessFlag != 0 { throw .cloudPlaceholder(url.path) }
        if getxattr(url.path, "com.apple.rootless", nil, 0, 0, XATTR_NOFOLLOW) >= 0 { throw .systemProtected(url.path) }
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func isOwnedByCurrentUser(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_uid == getuid()
    }
}
