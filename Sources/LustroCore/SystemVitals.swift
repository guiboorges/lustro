import Darwin
import Foundation

/// Whole-machine readings shown on the Maintenance screen.
public struct SystemVitals: Sendable, Equatable {
    public enum MemoryPressure: Sendable, Equatable { case normal, warning, critical }

    /// Share of all cores in use since the previous sample (0–100). Nil on the first sample.
    public let cpuPercent: Double?
    public let loadAverage: Double
    public let coreCount: Int
    /// What Activity Monitor calls "Memory Used": app memory + wired + compressed.
    public let memoryUsed: Int64
    public let memoryTotal: Int64
    public let memoryPressure: MemoryPressure
    public let swapUsed: Int64
    public let thermalState: ProcessInfo.ThermalState
}

/// Takes `SystemVitals` readings. CPU usage needs two samples, so keep one sampler around.
public final class VitalsSampler: @unchecked Sendable {
    private var previousTicks: [UInt32]?
    private let lock = NSLock()

    public init() {}

    public func sample() -> SystemVitals {
        let ticks = Self.cpuTicks()
        let cpu: Double? = lock.withLock {
            defer { previousTicks = ticks }
            guard let previous = previousTicks, let ticks else { return nil }
            return Self.cpuPercent(previous: previous, current: ticks)
        }
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        return SystemVitals(cpuPercent: cpu, loadAverage: load[0], coreCount: ProcessInfo.processInfo.activeProcessorCount,
                            memoryUsed: Self.memoryUsed(), memoryTotal: Int64(ProcessInfo.processInfo.physicalMemory),
                            memoryPressure: Self.memoryPressure(), swapUsed: Self.swapUsed(),
                            thermalState: ProcessInfo.processInfo.thermalState)
    }

    /// Busy share between two `HOST_CPU_LOAD_INFO` readings (user, system, idle, nice). Counters wrap.
    public static func cpuPercent(previous: [UInt32], current: [UInt32]) -> Double? {
        guard previous.count == 4, current.count == 4 else { return nil }
        let delta = zip(current, previous).map { Double($0 &- $1) }
        let total = delta.reduce(0, +)
        guard total > 0 else { return nil }
        return (total - delta[Int(CPU_STATE_IDLE)]) / total * 100
    }

    private static func cpuTicks() -> [UInt32]? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        return [t.0, t.1, t.2, t.3]
    }

    private static func memoryUsed() -> Int64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let appPages = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
        let pages = max(appPages, 0) + Int64(stats.wire_count) + Int64(stats.compressor_page_count)
        return pages * Int64(getpagesize())
    }

    private static func memoryPressure() -> SystemVitals.MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        switch level {
        case 4: return .critical
        case 2: return .warning
        default: return .normal
        }
    }

    private static func swapUsed() -> Int64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return Int64(usage.xsu_used)
    }
}
