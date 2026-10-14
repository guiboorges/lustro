import Foundation

/// How much care a group of items needs before removal.
public enum RiskLevel: String, Codable, Sendable, CaseIterable, Comparable {
    /// Regenerated automatically by the system or the owning app.
    case safe
    /// Usually fine to remove, but worth a quick look.
    case review
    /// May contain data the user wants to keep; never auto-selected.
    case caution

    private var rank: Int {
        switch self {
        case .safe: 0
        case .review: 1
        case .caution: 2
        }
    }

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool { lhs.rank < rhs.rank }
}

/// A single file or folder that a scanner proposes to remove.
public struct ScanItem: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let size: Int64
    public let isDirectory: Bool
    public let lastModified: Date?
    /// Short label shown next to the item, e.g. "JavaScript".
    public let note: String?
    /// Why the scanner flagged it, e.g. "Found next to package.json". Shown in "Why is this safe?".
    public let evidence: String?

    public init(url: URL, size: Int64, isDirectory: Bool, lastModified: Date? = nil, note: String? = nil, evidence: String? = nil) {
        self.url = url.standardizedFileURL
        self.size = size
        self.isDirectory = isDirectory
        self.lastModified = lastModified
        self.note = note
        self.evidence = evidence
    }

    public func with(note: String? = nil, evidence: String? = nil) -> ScanItem {
        ScanItem(url: url, size: size, isDirectory: isDirectory, lastModified: lastModified,
                 note: note ?? self.note, evidence: evidence ?? self.evidence)
    }
}

/// A named set of items shown together in the review UI.
public struct ScanGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let section: String
    public let risk: RiskLevel
    /// Whether items in this group start selected in the review list.
    public let autoSelect: Bool
    /// Bundle IDs known to own every item in the group (in addition to per-path detection).
    public let owners: [String]
    /// SF Symbol and accent colour name for the group's tile (e.g. "terminal", "teal").
    public let icon: String?
    public let tint: String?
    /// Last time the user worked in this group's project (Dev Purge).
    public let lastActivity: Date?
    public var items: [ScanItem]

    public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    public init(id: String, title: String, detail: String, section: String, risk: RiskLevel, autoSelect: Bool,
                owners: [String] = [], icon: String? = nil, tint: String? = nil, lastActivity: Date? = nil, items: [ScanItem]) {
        self.id = id
        self.title = title
        self.detail = detail
        self.section = section
        self.risk = risk
        self.autoSelect = autoSelect && risk != .caution
        self.owners = owners
        self.icon = icon
        self.tint = tint
        self.lastActivity = lastActivity
        self.items = items
    }
}

/// Progress reported while a scan runs.
public struct ScanProgress: Sendable {
    public let message: String
    public let fraction: Double?

    public init(message: String, fraction: Double? = nil) {
        self.message = message
        self.fraction = fraction
    }
}

public typealias ProgressHandler = @Sendable (ScanProgress) -> Void

public extension Int64 {
    /// Human-readable byte count, e.g. "1.2 GB".
    var formattedBytes: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false // "0 bytes" rather than "Zero KB"
        return formatter.string(fromByteCount: self)
    }
}
