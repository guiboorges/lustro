import Foundation

/// Measures how much disk space files and folders actually occupy.
public enum DiskUsage {
    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey, .contentModificationDateKey,
    ]

    /// Allocated size in bytes. Symlinks count as their own (tiny) size and are never followed.
    /// Unreadable descendants are skipped rather than failing the whole measurement.
    public static func allocatedSize(of url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
        if values.isSymbolicLink == true || values.isDirectory != true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        for case let child as URL in enumerator {
            if Task.isCancelled { break }
            guard let v = try? child.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// Builds a `ScanItem` for `url`, or nil if it does not exist.
    public static func item(for url: URL, note: String? = nil) -> ScanItem? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        let isDirectory = values.isDirectory == true && values.isSymbolicLink != true
        return ScanItem(
            url: url,
            size: allocatedSize(of: url),
            isDirectory: isDirectory,
            lastModified: values.contentModificationDate,
            note: note
        )
    }

    /// Most recent modification date of `url` or anything inside it, scanning at most `limit` entries.
    public static func latestModification(in url: URL, limit: Int = 20_000) -> Date? {
        var latest = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [], errorHandler: { _, _ in true }
        ) else { return latest }
        var seen = 0
        for case let child as URL in enumerator {
            seen += 1
            if seen > limit || Task.isCancelled { break }
            if let d = (try? child.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               d > (latest ?? .distantPast) {
                latest = d
            }
        }
        return latest
    }
}
