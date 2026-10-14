import Darwin
import Foundation

/// One process as shown under "Heavy processes".
public struct ProcessSample: Identifiable, Sendable, Equatable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let name: String
    public let path: String
    /// Outermost `.app` bundle the executable lives in, e.g. `/Applications/Firefox.app` for its GPU helper.
    public let appPath: String?
    public let appName: String?
    /// True for the bundle's own executable: quitting it closes the app.
    public let isAppMain: Bool
    /// Part of macOS, or owned by another user. Lustro never offers to quit these.
    public let isSystem: Bool
    /// CPU used since the previous sample. 100 = one full core.
    public let cpuPercent: Double
    /// CPU used on average since the process started.
    public let averageCPUPercent: Double
    /// Physical footprint, the "Memory" column in Activity Monitor.
    public let memory: Int64
    public let startDate: Date?

    public init(pid: Int32, name: String, path: String, appPath: String?, appName: String?, isAppMain: Bool, isSystem: Bool,
                cpuPercent: Double, averageCPUPercent: Double, memory: Int64, startDate: Date?) {
        self.pid = pid
        self.name = name
        self.path = path
        self.appPath = appPath
        self.appName = appName
        self.isAppMain = isAppMain
        self.isSystem = isSystem
        self.cpuPercent = cpuPercent
        self.averageCPUPercent = averageCPUPercent
        self.memory = memory
        self.startDate = startDate
    }

    public var runningTime: TimeInterval? { startDate.map { Date().timeIntervalSince($0) } }
}

/// Samples CPU and memory of the current user's processes. Other users' processes (root daemons)
/// can't be read without privileges, and couldn't be quit anyway.
public final class ProcessMonitor: @unchecked Sendable {
    /// Display name for a pid (e.g. "Firefox GPU Helper"), resolved by the app layer through LaunchServices.
    public typealias NameResolver = @Sendable (Int32) -> String?

    private struct Previous { let cpuNanos: UInt64; let date: Date }
    private var previous: [Int32: Previous] = [:]
    private let lock = NSLock()
    private let resolveName: NameResolver
    private let ownPID = getpid()
    private let uid = getuid()
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    public init(resolveName: @escaping NameResolver = { _ in nil }) {
        self.resolveName = resolveName
    }

    /// The busiest processes by CPU and by memory (`limit` of each), busiest first. CPU is measured
    /// against the previous call. Lustro itself is left out. Only these get the costlier lookups (path, name, app).
    public func sample(limit: Int = 12) -> [ProcessSample] {
        let now = Date()
        var raw: [(pid: Int32, cpu: Double, cpuNanos: UInt64, memory: Int64)] = []
        var current: [Int32: Previous] = [:]
        let last = lock.withLock { previous }
        for pid in Self.allPIDs() where pid > 0 && pid != ownPID {
            guard let usage = Self.usage(pid) else { continue }
            current[pid] = Previous(cpuNanos: usage.cpuNanos, date: now)
            var cpu = 0.0
            if let last = last[pid], usage.cpuNanos >= last.cpuNanos {
                cpu = Self.percent(nanos: usage.cpuNanos - last.cpuNanos, over: now.timeIntervalSince(last.date))
            }
            raw.append((pid, cpu, usage.cpuNanos, Int64(usage.footprint)))
        }
        lock.withLock { previous = current }

        let byCPU = raw.sorted { $0.cpu > $1.cpu }.prefix(limit)
        let byMemory = raw.sorted { $0.memory > $1.memory }.prefix(limit)
        var seen = Set<Int32>()
        var samples: [ProcessSample] = []
        for entry in byCPU + byMemory where seen.insert(entry.pid).inserted {
            guard let path = Self.path(entry.pid) else { continue }
            let started = Self.startDate(entry.pid)
            let average = started.map { Self.percent(nanos: entry.cpuNanos, over: now.timeIntervalSince($0)) } ?? 0
            let app = Self.enclosingApp(of: path)
            samples.append(ProcessSample(
                pid: entry.pid, name: resolveName(entry.pid) ?? Self.name(entry.pid) ?? (path as NSString).lastPathComponent,
                path: path, appPath: app, appName: app.map(Self.displayName(ofApp:)),
                isAppMain: app.map { Self.isMainExecutable(path, ofApp: $0) } ?? false,
                isSystem: Self.isSystemPath(path) || Self.owner(entry.pid) != uid,
                cpuPercent: entry.cpu, averageCPUPercent: average, memory: entry.memory, startDate: started))
        }
        return samples.sorted { $0.cpuPercent > $1.cpuPercent }
    }

    /// Still the same process (pids get reused, so the start time must match too).
    public static func isRunning(_ sample: ProcessSample) -> Bool {
        guard kill(sample.pid, 0) == 0 || errno == EPERM else { return false }
        return startDate(sample.pid) == sample.startDate
    }

    /// Sends `signal` to a process Lustro is allowed to quit. Refuses system processes and reused pids.
    @discardableResult
    public static func send(_ signal: Int32, to sample: ProcessSample) -> Bool {
        guard !sample.isSystem, sample.pid > 1, isRunning(sample) else { return false }
        return kill(sample.pid, signal) == 0
    }

    // MARK: - Pure helpers

    /// 100 = one core busy for the whole interval.
    public static func percent(nanos: UInt64, over seconds: TimeInterval) -> Double {
        guard seconds > 0 else { return 0 }
        return Double(nanos) / 1e9 / seconds * 100
    }

    /// The outermost `.app` in `path`, so helpers nested inside an app are attributed to it.
    public static func enclosingApp(of path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let index = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return parts[...index].joined(separator: "/")
    }

    /// `Firefox.app/Contents/MacOS/firefox` is the app; `Firefox.app/Contents/MacOS/plugin-container.app/…` is a helper.
    public static func isMainExecutable(_ path: String, ofApp app: String) -> Bool {
        let rest = path.dropFirst(app.count)
        return rest.hasPrefix("/Contents/MacOS/") && !rest.dropFirst("/Contents/MacOS/".count).contains("/")
    }

    public static func isSystemPath(_ path: String) -> Bool {
        ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/", "/private/var/", "/Applications/Xcode.app/Contents/Developer/"]
            .contains { path.hasPrefix($0) }
            || path.hasPrefix("/Library/Developer/CommandLineTools/")
    }

    static func displayName(ofApp path: String) -> String {
        let bundle = Bundle(path: path)
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
        return name ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    // MARK: - Kernel queries

    private static func allPIDs() -> [Int32] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(count, 0))))
    }

    private static func usage(_ pid: Int32) -> (cpuNanos: UInt64, footprint: UInt64)? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        // rusage times are in Mach absolute-time units, which are not nanoseconds on Apple silicon.
        let ticks = info.ri_user_time + info.ri_system_time
        return (ticks * timebase.numer / timebase.denom, info.ri_phys_footprint)
    }

    private static func path(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return string(buffer)
    }

    private static func name(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return string(buffer)
    }

    private static func string(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private static func startDate(_ pid: Int32) -> Date? {
        guard let info = bsdInfo(pid), info.pbi_start_tvsec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1e6)
    }

    private static func owner(_ pid: Int32) -> uid_t? {
        bsdInfo(pid)?.pbi_uid
    }
}
