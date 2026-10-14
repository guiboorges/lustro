import Foundation

/// One entry in the Space Lens view: a file or folder with its total size.
public struct SpaceNode: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let size: Int64
    public let isDirectory: Bool
    public var name: String { url.lastPathComponent }
}

/// Size index built from a single walk of a folder tree.
///
/// The walk records the total size of every folder down to `indexDepth` levels,
/// so browsing those levels is instant. Deeper folders are measured on demand.
public final class SpaceIndex: @unchecked Sendable {
    public let root: URL
    public let indexDepth: Int
    private let lock = NSLock()
    private var folderSizes: [String: Int64] = [:]
    public private(set) var scannedFiles = 0

    public init(root: URL, indexDepth: Int = 6) {
        self.root = root.standardizedFileURL
        self.indexDepth = indexDepth
    }

    /// Walks the whole tree once. Call from a background task.
    public func build(progress: ProgressHandler? = nil) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }
        ) else { return }

        var sizes: [String: Int64] = [root.path: 0]
        var ancestors: [String] = [root.path] // ancestors[level - 1] is the parent folder at that level
        var files = 0

        for case let url as URL in enumerator {
            if Task.isCancelled { break }
            let level = enumerator.level
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if ancestors.count > level { ancestors.removeLast(ancestors.count - level) }

            if v.isDirectory == true && v.isSymbolicLink != true {
                ancestors.append(url.path)
                if level <= indexDepth { sizes[url.path, default: 0] += 0 }
                continue
            }

            let size = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            for (depth, folder) in ancestors.enumerated() where depth <= indexDepth {
                sizes[folder, default: 0] += size
            }
            files += 1
            if files % 5_000 == 0 {
                progress?(ScanProgress(message: "\(files.formatted()) files · \(Int64(sizes[root.path] ?? 0).formattedBytes)"))
            }
        }
        lock.withLock {
            folderSizes = sizes
            scannedFiles = files
        }
    }

    public var totalSize: Int64 { lock.withLock { folderSizes[root.path] ?? 0 } }

    /// Direct children of `folder`, largest first.
    public func children(of folder: URL) -> [SpaceNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [])) ?? []
        return entries.compactMap { url -> SpaceNode? in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let isDir = v.isDirectory == true && v.isSymbolicLink != true
            let size: Int64
            if isDir {
                size = lock.withLock { folderSizes[url.standardizedFileURL.path] } ?? DiskUsage.allocatedSize(of: url)
            } else {
                size = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            }
            return SpaceNode(url: url, size: size, isDirectory: isDir)
        }
        .sorted { $0.size > $1.size }
    }

    /// Updates the index after `url` was removed.
    public func forget(_ url: URL, size: Int64) {
        lock.withLock {
            let path = url.standardizedFileURL.path
            folderSizes = folderSizes.filter { !SafetyPolicy.isSameOrInside($0.key, path) }
            var parent = url.standardizedFileURL.deletingLastPathComponent()
            while SafetyPolicy.isSameOrInside(parent.path, root.path) {
                if let current = folderSizes[parent.path] { folderSizes[parent.path] = max(0, current - size) }
                if parent.path == root.path { break }
                parent.deleteLastPathComponent()
            }
        }
    }
}
