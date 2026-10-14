import Foundation

/// One line in the "Why is this safe?" popover.
public struct Reason: Hashable, Sendable {
    public enum Kind: Sendable { case ok, warning, info }
    public let kind: Kind
    public let text: String

    public init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }
}

/// Builds human-readable reasons for why an item was offered for removal.
/// Every reason is derived from data Lustro actually checked; nothing is guessed.
public struct Explainer: Sendable {
    public let policy: SafetyPolicy
    public let now: Date

    public init(policy: SafetyPolicy, now: Date = Date()) {
        self.policy = policy
        self.now = now
    }

    /// - Parameters:
    ///   - ownerName: display name of the owning app, when the app layer could resolve it.
    ///   - runningOwners: open apps that own the item.
    public func reasons(for item: ScanItem, in group: ScanGroup, ownerName: String?, runningOwners: [RunningApp]) -> [Reason] {
        var reasons: [Reason] = []
        let key = AppOwnership(home: policy.home).ownerKey(for: item.url) ?? group.owners.first

        if let ownerName, let key, ownerName != key {
            reasons.append(Reason(.ok, "Belongs to \(ownerName) (\(key))"))
        } else if let ownerName {
            reasons.append(Reason(.ok, "Belongs to \(ownerName)"))
        } else if let key {
            reasons.append(Reason(.ok, "Belongs to \(key)"))
        }

        if group.id == LeftoverScanner.groupID {
            reasons.append(Reason(.info, "Not recreated: its app is no longer installed. It goes to the Trash, so you can put it back"))
        } else if group.id == "app-data" {
            reasons.append(Reason(.warning, "Your data in this app. Removing it can't be undone once the Trash is emptied"))
        }

        switch group.risk {
        case .safe: reasons.append(Reason(.ok, "Recreated automatically when it's needed again"))
        case .review: reasons.append(Reason(.info, "Usually safe to remove, but worth a quick look"))
        case .caution: reasons.append(Reason(.warning, "May hold data you want to keep. Never preselected"))
        }

        if let evidence = item.evidence { reasons.append(Reason(.ok, evidence)) }

        if let modified = item.lastModified {
            let days = Int(now.timeIntervalSince(modified) / 86_400)
            if days >= 1 {
                reasons.append(Reason(.ok, "Not modified in the last \(days) day\(days == 1 ? "" : "s")"))
            } else {
                reasons.append(Reason(.warning, "Modified in the last 24 hours, it may be in use"))
            }
        }

        do {
            try policy.validate(item.url)
            reasons.append(Reason(.ok, "Not a protected folder · no symlinks · not in iCloud · not locked"))
        } catch {
            reasons.append(Reason(.warning, error.description))
        }

        for app in runningOwners {
            reasons.append(Reason(.warning, "\(app.name) is open: you'll be asked to quit it first"))
        }
        return reasons
    }
}
