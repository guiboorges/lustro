import Foundation
import SQLite3

/// Runs a command-line tool and returns its exit status and combined output. Blocks: call off the main thread.
public enum Shell {
    /// `timeout` stops the tool if it hangs (e.g. a CLI waiting on a daemon that doesn't answer).
    @discardableResult
    public static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval? = nil) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [process] in
                if process.isRunning { process.terminate() }
            }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// Time Machine's local snapshots: purgeable space macOS reclaims on its own when the disk fills up.
public enum LocalSnapshots {
    public static func list(volume: String = "/") -> [String] {
        parse(Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", volume]).output)
    }

    /// Lines like `com.apple.TimeMachine.2026-10-14-101010.local`; skips the "Snapshots for disk /:" header.
    public static func parse(_ output: String) -> [String] {
        output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("com.apple.") && $0.contains("TimeMachine") }
    }

    /// Space the system counts as available for important data but not free yet (snapshots, caches it can purge).
    public static func purgeableBytes(volume: URL = URL(fileURLWithPath: "/")) -> Int64 {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? volume.resourceValues(forKeys: keys),
              let free = values.volumeAvailableCapacity,
              let important = values.volumeAvailableCapacityForImportantUsage else { return 0 }
        return max(important - Int64(free), 0)
    }

    /// Asks Time Machine to reclaim as much snapshot space as it can, at the highest urgency.
    public static func thin(volume: String = "/") -> (ok: Bool, output: String) {
        let result = Shell.run("/usr/bin/tmutil", ["thinlocalsnapshots", volume, "999999999999", "4"])
        return (result.status == 0, result.output)
    }
}

/// Mail's message index (`Envelope Index`), which grows and fragments over the years.
public enum MailIndex {
    public static func files(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let mail = home.appendingPathComponent("Library/Mail")
        let versions = (try? FileManager.default.contentsOfDirectory(at: mail, includingPropertiesForKeys: nil)) ?? []
        return versions
            .filter { $0.lastPathComponent.hasPrefix("V") }
            .map { $0.appendingPathComponent("MailData/Envelope Index") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func size(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Int64 {
        files(home: home).reduce(0) {
            $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case open(String), vacuum(String)
        public var description: String {
            switch self {
            case .open(let m): "Couldn't open Mail's index: \(m)"
            case .vacuum(let m): "Couldn't compact Mail's index: \(m)"
            }
        }
    }

    /// Rewrites the index without its free pages. Mail must be closed. SQLite does this in a transaction,
    /// so an interruption leaves the original intact.
    public static func compact(_ url: URL) throws(Failure) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw .open(message)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)
        guard sqlite3_exec(db, "VACUUM;", nil, nil, nil) == SQLITE_OK else {
            throw .vacuum(String(cString: sqlite3_errmsg(db)))
        }
    }
}

/// Fixes that need an administrator. The app runs them through the standard password prompt.
public enum AdminTask: String, Sendable, CaseIterable {
    case flushDNS
    case rebuildSpotlight

    public var command: String {
        switch self {
        case .flushDNS: "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder"
        case .rebuildSpotlight: "/usr/bin/mdutil -E /"
        }
    }
}
