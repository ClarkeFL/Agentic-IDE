import Darwin
import Foundation
import Observation

/// Samples *system-wide* CPU and memory at 2 Hz so the UI can show
/// "what is my Mac using right now" without sending the user to
/// Activity Monitor.
///
/// CPU comes from `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` —
/// monotonic per-core tick counters in {user, system, nice, idle}. We
/// take a delta between consecutive samples so the percent reflects the
/// last 500ms of activity. 100% = every core fully busy (matches
/// Activity Monitor's CPU header).
///
/// Memory comes from `host_statistics64(HOST_VM_INFO64)`. "Used" follows
/// Activity Monitor's "Memory Used" definition: active + wired +
/// compressed pages. Total comes from `ProcessInfo.physicalMemory`.
///
/// All access is from the main thread (the timer schedules on
/// `RunLoop.main`); the underlying mach calls are thread-safe so the
/// sampler itself doesn't need locking.
@Observable
final class ResourceMonitor {
    /// System CPU% — 0–100, where 100 = every core saturated.
    private(set) var cpuPercent: Double = 0
    /// Bytes of physical memory currently in use (active + wired + compressed).
    private(set) var memoryUsedBytes: Int = 0
    /// Total physical memory installed on the machine.
    private(set) var memoryTotalBytes: Int = Int(ProcessInfo.processInfo.physicalMemory)

    @ObservationIgnored
    private var timer: Timer?

    /// Tick totals from the previous CPU sample. Required because
    /// `PROCESSOR_CPU_LOAD_INFO` reports cumulative ticks since boot —
    /// the percent is the delta over the sampling window, not the
    /// instantaneous value.
    @ObservationIgnored
    private var lastCPUTotalTicks: Double = 0
    @ObservationIgnored
    private var lastCPUBusyTicks: Double = 0

    init() { start() }

    deinit { timer?.invalidate() }

    func start() {
        guard timer == nil else { return }
        // Prime the CPU delta — first sample from boot gives a meaningless
        // average over the whole uptime, so we capture totals once and
        // start reporting on the next tick.
        _ = Self.sampleCPUTicks()
        memoryUsedBytes = Self.sampleMemoryUsed()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.sample()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        let ticks = Self.sampleCPUTicks()
        let dTotal = ticks.total - lastCPUTotalTicks
        let dBusy = ticks.busy - lastCPUBusyTicks
        lastCPUTotalTicks = ticks.total
        lastCPUBusyTicks = ticks.busy
        cpuPercent = dTotal > 0 ? (dBusy / dTotal) * 100.0 : 0
        memoryUsedBytes = Self.sampleMemoryUsed()
    }

    /// Sums `{user, system, nice}` and `{user, system, nice, idle}` ticks
    /// across every CPU. Returning the totals (rather than the percent)
    /// lets the caller take a delta for the sampling window.
    private static func sampleCPUTicks() -> (busy: Double, total: Double) {
        var cpuCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &infoArray,
            &infoCount
        )
        guard kr == KERN_SUCCESS, let infoArray else { return (0, 0) }
        defer {
            let baseAddr = vm_address_t(UInt(bitPattern: Int(bitPattern: infoArray)))
            vm_deallocate(mach_task_self_,
                          baseAddr,
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.size))
        }

        let stateCount = Int(CPU_STATE_MAX)
        var busy: Double = 0
        var total: Double = 0
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * stateCount
            let user = Double(infoArray[base + Int(CPU_STATE_USER)])
            let system = Double(infoArray[base + Int(CPU_STATE_SYSTEM)])
            let nice = Double(infoArray[base + Int(CPU_STATE_NICE)])
            let idle = Double(infoArray[base + Int(CPU_STATE_IDLE)])
            busy += user + system + nice
            total += user + system + nice + idle
        }
        return (busy, total)
    }

    /// "Memory Used" per Activity Monitor: pages that are actively in
    /// use, wired by the kernel, or compressed by the OS to reclaim
    /// physical RAM. Doesn't count file-cache (inactive) or free pages.
    private static func sampleMemoryUsed() -> Int {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(),
                                  HOST_VM_INFO64,
                                  $0,
                                  &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let pageSize = Int(vm_kernel_page_size)
        let active = Int(stats.active_count) * pageSize
        let wired = Int(stats.wire_count) * pageSize
        let compressed = Int(stats.compressor_page_count) * pageSize
        return active + wired + compressed
    }
}
