import Foundation

/// A launchd job from one of the LaunchAgents/LaunchDaemons folders: something that starts on its own.
public struct LaunchItem: Identifiable, Sendable, Equatable {
    public enum Scope: String, Sendable {
        /// `~/Library/LaunchAgents`: runs for you only.
        case user
        /// `/Library/LaunchAgents`: runs for every user, in each user's session.
        case allUsers
        /// `/Library/LaunchDaemons`: runs as root. Changing these needs an administrator.
        case system
    }

    public var id: String { plist.path }
    public let label: String
    public let plist: URL
    public let scope: Scope
    /// Executable it starts, when it's an absolute path.
    public let program: String?
    /// App the executable lives in, e.g. `/Applications/Docker.app`.
    public let appPath: String?
    /// Bundle IDs the plist names as its owner (`AssociatedBundleIdentifiers`), plus guesses from the label.
    public let candidateBundleIDs: [String]
    /// Its program no longer exists, usually because the app was deleted.
    public let isBroken: Bool
    public var isDisabled: Bool

    /// Agents run in your session, so you can switch them off for yourself without a password.
    public var canToggle: Bool { scope != .system && !isBroken }
    /// Only your own broken agents can be moved to the Trash without a password.
    public var canRemove: Bool { scope == .user && isBroken }
}

public struct LaunchItemScanner: Sendable {
    public let home: URL
    public let systemRoot: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, systemRoot: URL = URL(fileURLWithPath: "/")) {
        self.home = home
        self.systemRoot = systemRoot
    }

    /// Third-party agents, plus daemons whose program is missing. Apple's own jobs are left out.
    public func scan(disabledLabels: Set<String>) -> [LaunchItem] {
        let folders: [(URL, LaunchItem.Scope)] = [
            (home.appendingPathComponent("Library/LaunchAgents"), .user),
            (systemRoot.appendingPathComponent("Library/LaunchAgents"), .allUsers),
            (systemRoot.appendingPathComponent("Library/LaunchDaemons"), .system),
        ]
        var items: [LaunchItem] = []
        let fileManager = FileManager.default
        for (folder, scope) in folders {
            let files = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "plist" {
                guard let data = try? Data(contentsOf: file),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let label = plist["Label"] as? String, !label.hasPrefix("com.apple.") else { continue }
                let program = Self.program(from: plist)
                let broken = program.map { !fileManager.fileExists(atPath: $0) } ?? false
                if scope == .system && !broken { continue }
                let associated = plist["AssociatedBundleIdentifiers"] as? [String] ?? (plist["AssociatedBundleIdentifiers"] as? String).map { [$0] } ?? []
                items.append(LaunchItem(label: label, plist: file, scope: scope, program: program,
                                        appPath: program.flatMap(ProcessMonitor.enclosingApp(of:)),
                                        candidateBundleIDs: associated + Self.bundleIDGuesses(fromLabel: label),
                                        isBroken: broken, isDisabled: disabledLabels.contains(label)))
            }
        }
        return items.sorted {
            ($0.isBroken ? 2 : $0.isDisabled ? 1 : 0, $0.label.lowercased()) < ($1.isBroken ? 2 : $1.isDisabled ? 1 : 0, $1.label.lowercased())
        }
    }

    /// `Program`, or the first of `ProgramArguments`, when it's an absolute path.
    public static func program(from plist: [String: Any]) -> String? {
        let candidate = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first
        guard let candidate, candidate.hasPrefix("/") else { return nil }
        return candidate
    }

    /// `com.docker.helper` → `com.docker.helper`, `com.docker`. Two components minimum.
    public static func bundleIDGuesses(fromLabel label: String) -> [String] {
        let parts = label.split(separator: ".")
        guard parts.count >= 2 else { return [] }
        return (2...parts.count).reversed().map { parts.prefix($0).joined(separator: ".") }
    }

    /// Parses `launchctl print-disabled gui/<uid>`: lines like `"com.adobe.GC.AGM" => disabled` (or `=> true` on older systems).
    public static func parseDisabled(_ output: String) -> Set<String> {
        var labels = Set<String>()
        for line in output.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let state = parts[1].trimmingCharacters(in: .whitespaces)
            guard state == "disabled" || state == "true" else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !label.isEmpty { labels.insert(label) }
        }
        return labels
    }
}

/// Switches agents on and off in your own launchd session (`gui/<uid>`). No password needed.
public enum LaunchControl {
    static var domain: String { "gui/\(getuid())" }

    public static func disabledLabels() -> Set<String> {
        LaunchItemScanner.parseDisabled(Shell.run("/bin/launchctl", ["print-disabled", domain]).output)
    }

    /// Disabling is remembered by launchd across restarts; the job is also stopped now.
    @discardableResult
    public static func setEnabled(_ enabled: Bool, _ item: LaunchItem) -> Bool {
        guard item.canToggle else { return false }
        let target = "\(domain)/\(item.label)"
        let result = Shell.run("/bin/launchctl", [enabled ? "enable" : "disable", target])
        if enabled {
            Shell.run("/bin/launchctl", ["bootstrap", domain, item.plist.path])
        } else {
            Shell.run("/bin/launchctl", ["bootout", target])
        }
        return result.status == 0
    }

    /// Stops a job before its plist is removed. Errors are expected when it isn't loaded.
    public static func stop(_ item: LaunchItem) {
        Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(item.label)"])
    }
}
