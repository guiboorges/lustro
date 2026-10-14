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
        case open(String), vacuum(String), backup(String)
        public var description: String {
            switch self {
            case .backup(let m): String(localized: "Couldn't make a safety copy of Mail's index, so nothing was changed: \(m)")
            case .open(let m): String(localized: "Couldn't open Mail's index: \(m)")
            case .vacuum(let m): String(localized: "Couldn't compact Mail's index: \(m)")
            }
        }
    }

    /// Rewrites the index without its free pages. Mail must be closed. SQLite does this in a transaction, so an
    /// interruption leaves the original intact; on top of that, the index (and its -wal/-shm files) is cloned first
    /// (instant on APFS) and the copy is only removed once the database checks out.
    public static func compact(_ url: URL) throws(Failure) {
        let fileManager = FileManager.default
        let parts = [url] + ["-wal", "-shm"].map { URL(fileURLWithPath: url.path + $0) }.filter { fileManager.fileExists(atPath: $0.path) }
        let backups = parts.map { URL(fileURLWithPath: $0.path + ".lustro-backup") }
        for backup in backups { try? fileManager.removeItem(at: backup) }
        do {
            for (part, backup) in zip(parts, backups) { try fileManager.copyItem(at: part, to: backup) }
        } catch {
            for backup in backups { try? fileManager.removeItem(at: backup) }
            throw .backup(error.localizedDescription)
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            for backup in backups { try? fileManager.removeItem(at: backup) }
            throw .open(message)
        }
        sqlite3_busy_timeout(db, 5000)
        let vacuumed = sqlite3_exec(db, "VACUUM;", nil, nil, nil) == SQLITE_OK
        let error = vacuumed ? nil : String(cString: sqlite3_errmsg(db))
        let healthy = vacuumed && integrityCheck(db)
        sqlite3_close(db)
        if healthy {
            for backup in backups { try? fileManager.removeItem(at: backup) }
        } else if vacuumed {
            // VACUUM succeeded but the result looks wrong: put the original back.
            for (part, backup) in zip(parts, backups) {
                _ = try? fileManager.replaceItemAt(part, withItemAt: backup)
            }
            throw .vacuum(String(localized: "The compacted index failed its check, so the original was put back."))
        } else {
            // SQLite rolled back; the original is untouched, so the copy isn't needed.
            for backup in backups { try? fileManager.removeItem(at: backup) }
            throw .vacuum(error ?? "unknown error")
        }
    }

    private static func integrityCheck(_ db: OpaquePointer?) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA quick_check;", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return false }
        return String(cString: text) == "ok"
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
