import Darwin
import Foundation

/// A process with its family ties (parent, terminal) and what it was started with.
public struct ProcessEntry: Identifiable, Sendable, Equatable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let ppid: Int32
    /// Terminal device name, e.g. `ttys003`. Nil for processes without a terminal.
    public let tty: String?
    public let name: String
    public let path: String
    /// Command-line arguments (argv). Only read for command-line processes; empty otherwise.
    public let arguments: [String]
    /// Working directory. Only read for command-line processes.
    public let cwd: String?
    public let startDate: Date?
    /// CPU since the previous sample. 100 = one core.
    public let cpuPercent: Double
    public let memory: Int64
    public let isSystem: Bool

    public init(pid: Int32, ppid: Int32, tty: String?, name: String, path: String, arguments: [String], cwd: String?,
                startDate: Date?, cpuPercent: Double, memory: Int64, isSystem: Bool) {
        self.pid = pid
        self.ppid = ppid
        self.tty = tty
        self.name = name
        self.path = path
        self.arguments = arguments
        self.cwd = cwd
        self.startDate = startDate
        self.cpuPercent = cpuPercent
        self.memory = memory
        self.isSystem = isSystem
    }

    public var appPath: String? { ProcessMonitor.enclosingApp(of: path) }
    public var runningTime: TimeInterval? { startDate.map { Date().timeIntervalSince($0) } }
    /// `argv[0]` without its folder and login-shell dash, falling back to the process name.
    public var command: String {
        let first = arguments.first.map { (($0 as NSString).lastPathComponent) } ?? name
        return first.hasPrefix("-") ? String(first.dropFirst()) : first
    }
}

/// A TCP port a process is listening on.
public struct ListeningPort: Identifiable, Sendable, Equatable {
    public var id: String { "\(pid):\(port)" }
    public let pid: Int32
    public let port: Int
    /// Bound to all interfaces, so other devices on the network can connect.
    public let exposed: Bool

    public init(pid: Int32, port: Int, exposed: Bool) {
        self.pid = pid
        self.port = port
        self.exposed = exposed
    }
}

/// Reads every process the current user owns, with parents, terminals, arguments and listening ports.
/// Nothing here needs administrator rights.
public final class ProcessTable: @unchecked Sendable {
    private var previous: [Int32: (cpuNanos: UInt64, date: Date)] = [:]
    /// Arguments never change during a process's life, so they're read once per pid and start time.
    private var argumentCache: [Int32: (start: Date?, arguments: [String])] = [:]
    private let lock = NSLock()
    private let uid = getuid()
    private let ownPID = getpid()

    public init() {}

    /// Listing every process's sockets is the costly part, so callers can skip ports on some samples.
    public func sample(includePorts: Bool = true) -> (processes: [ProcessEntry], ports: [ListeningPort]) {
        let now = Date()
        let (last, cachedArguments) = lock.withLock { (previous, argumentCache) }
        var arguments: [Int32: (start: Date?, arguments: [String])] = [:]
        var current: [Int32: (cpuNanos: UInt64, date: Date)] = [:]
        var entries: [ProcessEntry] = []
        var ports: [ListeningPort] = []
        for pid in ProcessMonitor.allPIDs() where pid > 0 && pid != ownPID {
            guard let info = ProcessMonitor.bsdInfo(pid), info.pbi_uid == uid,
                  let usage = ProcessMonitor.usage(pid), let path = ProcessMonitor.path(pid) else { continue }
            current[pid] = (usage.cpuNanos, now)
            var cpu = 0.0
            if let before = last[pid], usage.cpuNanos >= before.cpuNanos {
                cpu = ProcessMonitor.percent(nanos: usage.cpuNanos - before.cpuNanos, over: now.timeIntervalSince(before.date))
            }
            let system = Self.isSystemComponent(path)
            // Arguments and working directory matter for command-line tools and agents, not for app helpers.
            let detailed = !system && (ProcessMonitor.enclosingApp(of: path) == nil || path.contains("/claude-code/"))
            let started = ProcessMonitor.startDate(pid)
            if detailed {
                if let cached = cachedArguments[pid], cached.start == started {
                    arguments[pid] = cached
                } else {
                    arguments[pid] = (started, Self.normalized(Self.arguments(pid)))
                }
            }
            entries.append(ProcessEntry(
                pid: pid, ppid: Int32(info.pbi_ppid), tty: Self.ttyName(info.e_tdev),
                name: ProcessMonitor.name(pid) ?? (path as NSString).lastPathComponent, path: path,
                arguments: arguments[pid]?.arguments ?? [], cwd: detailed ? Self.cwd(pid) : nil,
                startDate: started,
                cpuPercent: cpu, memory: Int64(usage.footprint), isSystem: system))
            if includePorts && !system { ports += Self.listeningPorts(pid) }
        }
        lock.withLock {
            previous = current
            argumentCache = arguments
        }
        return (entries, ports)
    }

    /// Parts of macOS itself (daemons, agents, frameworks). Tools like `/bin/bash` or `/usr/bin/python3`
    /// are not: when you run them, they're your processes.
    public static func isSystemComponent(_ path: String) -> Bool {
        ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"].contains { path.hasPrefix($0) }
    }

    /// Asks every process in the list to stop (or kills it, with SIGKILL). Skips macOS components and any pid
    /// that now belongs to a different process. Returns how many were signalled.
    @discardableResult
    public static func signal(_ signal: Int32, _ processes: [ProcessEntry]) -> Int {
        processes.filter { entry in
            guard !entry.isSystem, entry.pid > 1, isRunning(entry) else { return false }
            return kill(entry.pid, signal) == 0
        }.count
    }

    public static func isRunning(_ entry: ProcessEntry) -> Bool {
        guard kill(entry.pid, 0) == 0 || errno == EPERM else { return false }
        return ProcessMonitor.startDate(entry.pid) == entry.startDate
    }

    /// Seconds since someone typed in this terminal (the device's access time, as `w` reports it).
    public static func idleTime(tty: String) -> TimeInterval? {
        var info = stat()
        guard stat("/dev/\(tty)", &info) == 0 else { return nil }
        return Date().timeIntervalSince1970 - TimeInterval(info.st_atimespec.tv_sec)
    }

    // MARK: - Kernel queries

    private static func ttyName(_ device: UInt32) -> String? {
        guard device != UInt32.max, device != 0, let name = devname(dev_t(bitPattern: device), mode_t(S_IFCHR)) else { return nil }
        let text = String(cString: name)
        return text.isEmpty || text == "??" ? nil : text
    }

    private static let argMax: Int = {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctl(&mib, 2, &value, &size, nil, 0) == 0 ? Int(value) : 262_144
    }()

    /// argv from `KERN_PROCARGS2`: argc, the executable path, padding, then the arguments.
    static func arguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = argMax
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    /// Tools that rename themselves (npm sets `process.title`) leave the whole command line in argv[0].
    static func normalized(_ arguments: [String]) -> [String] {
        // The rest of the original argv area is left blank.
        guard let first = arguments.first, first.contains(" "), !FileManager.default.fileExists(atPath: first),
              arguments.dropFirst().allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return arguments }
        return first.split(separator: " ").map(String.init)
    }

    static func parseProcArgs(_ buffer: [UInt8]) -> [String] {
        guard buffer.count > 4 else { return [] }
        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var index = 4
        while index < buffer.count && buffer[index] != 0 { index += 1 }   // executable path
        while index < buffer.count && buffer[index] == 0 { index += 1 }   // padding
        var arguments: [String] = []
        while arguments.count < argc && index < buffer.count {
            let start = index
            while index < buffer.count && buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    private static func cwd(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }

    private static func listeningPorts(_ pid: Int32) -> [ListeningPort] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 8)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard used > 0 else { return [] }
        var ports: [ListeningPort] = []
        for fd in fds.prefix(Int(used) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var socket = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socket, size) == size,
                  socket.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = socket.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let address = tcp.tcpsi_ini
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: address.insi_lport)))
            let exposed: Bool
            if address.insi_vflag & UInt8(INI_IPV4) != 0 {
                let ipv4 = UInt32(bigEndian: address.insi_laddr.ina_46.i46a_addr4.s_addr)
                exposed = ipv4 >> 24 != 127
            } else {
                let ipv6 = withUnsafeBytes(of: address.insi_laddr.ina_6) { Array($0) }
                let loopback = ipv6.dropLast().allSatisfy { $0 == 0 } && ipv6.last == 1
                exposed = !loopback
            }
            if !ports.contains(where: { $0.port == port }) || exposed {
                ports.removeAll { $0.port == port }
                ports.append(ListeningPort(pid: pid, port: port, exposed: exposed))
            }
        }
        return ports
    }
}
