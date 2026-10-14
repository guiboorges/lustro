import Foundation

/// Expands simple glob patterns such as `~/Library/Containers/*/Data/Library/Caches`.
///
/// Supported syntax: a leading `~`, and `*`, `?`, `[...]` inside any path segment.
/// `**` is intentionally unsupported to keep scans bounded and predictable.
public enum PathPattern {
    public static func expand(_ pattern: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        var path = pattern
        if path == "~" {
            path = home.path
        } else if path.hasPrefix("~/") {
            path = home.path + String(path.dropFirst(1))
        }
        guard path.hasPrefix("/") else { return [] }

        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        // Patterns name places; `..` would let one climb out of the folder it names.
        guard !segments.contains(where: { $0 == "." || $0 == ".." }) else { return [] }
        var current: [URL] = [URL(fileURLWithPath: "/")]
        for segment in segments {
            var next: [URL] = []
            for base in current {
                if hasWildcard(segment) {
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
                    for name in names.sorted() where matches(name, segment) {
                        next.append(base.appendingPathComponent(name))
                    }
                } else {
                    let candidate = base.appendingPathComponent(segment)
                    if exists(candidate) { next.append(candidate) }
                }
            }
            current = next
            if current.isEmpty { break }
        }
        return current
    }

    public static func hasWildcard(_ s: String) -> Bool {
        s.contains("*") || s.contains("?") || s.contains("[")
    }

    /// Shell-style match of a single name against a pattern (no `/`).
    public static func matches(_ name: String, _ pattern: String) -> Bool {
        fnmatch(pattern, name, 0) == 0
    }

    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
}
