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

    public var description: String {
        switch self {
        case .notAbsolute(let p): "Path is not absolute: \(p)"
        case .protectedPath(let p): "Protected location, never removed: \(p)"
        case .insideDeniedLocation(let p): "Inside a location Limpo never touches: \(p)"
        case .outsideAllowedRoots(let p): "Outside the folders Limpo is allowed to clean: \(p)"
        case .ignoredByUser(let p): "On your ignore list: \(p)"
        case .notOwnedByUser(let p): "Not owned by you: \(p)"
        case .missing(let p): "No longer exists: \(p)"
        case .systemProtected(let p): "Protected by macOS (SIP, restricted or locked): \(p)"
        case .cloudPlaceholder(let p): "Only in iCloud, not on this Mac: \(p)"
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

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                extraAllowedRoots: [URL] = [],
                ignoredPaths: [URL] = []) {
        self.home = home.standardizedFileURL.resolvingSymlinksInPath()
        self.extraAllowedRoots = extraAllowedRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        self.ignoredPaths = ignoredPaths.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    }

    /// Shared temporary directories where only files owned by the current user may be removed.
    static let userOwnedTempRoots = ["/private/tmp", "/private/var/tmp"]

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
                            "Library/Application Support/Limpo"]
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

        for candidate in Set([standardized.path, real.path]) {
            if protectedExactPaths.contains(candidate) { throw .protectedPath(candidate) }
            if let prefix = deniedPrefixes.first(where: { Self.isSameOrInside(candidate, $0) }) {
                throw .insideDeniedLocation(prefix)
            }
            if ignoredPaths.contains(where: { Self.isSameOrInside(candidate, $0.path) }) {
                throw .ignoredByUser(candidate)
            }
        }

        guard (try? real.checkResourceIsReachable()) == true
                || fileManager.fileExists(atPath: real.path)
                || isSymlink(real) else {
            throw .missing(real.path)
        }

        try checkFileFlags(real)

        let allowedRoots = [home] + extraAllowedRoots
        if allowedRoots.contains(where: { Self.isStrictlyInside(real.path, $0.path) }) {
            return
        }
        if Self.userOwnedTempRoots.contains(where: { Self.isStrictlyInside(real.path, $0) }) {
            guard isOwnedByCurrentUser(real) else { throw .notOwnedByUser(real.path) }
            return
        }
        throw .outsideAllowedRoots(real.path)
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
    /// iCloud placeholders whose data is not on this Mac. Unlike some cleaners, Limpo never
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
