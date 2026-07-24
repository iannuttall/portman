import Darwin
import Foundation

/// Samples CPU, memory, thread count, start time and energy for a set of pids.
///
/// CPU and energy are rates, so they only exist as a difference between two readings.
/// The actor holds the previous reading per pid; the first sample of a pid therefore
/// reports `nil` for both rather than inventing a number from the process lifetime.
///
/// Every reading is best-effort: `proc_pidinfo` and `proc_pid_rusage` refuse processes
/// owned by root or another user, and that is the normal case for half of `lsof` output.
/// A refused call leaves the corresponding field `nil`; nothing here throws or traps.
actor ProcessMetricsSampler {
    /// The raw counters we diff between calls. All three are monotonic per process.
    private struct Reading {
        let cpuNanos: Double
        let energy: UInt64
        let wakeups: UInt64
        let at: Date
    }

    private var previous: [Int32: Reading] = [:]

    func sample(pids: [Int32]) -> [Int32: ProcessSample] {
        let now = Date()
        let requested = Set(pids)
        var samples: [Int32: ProcessSample] = [:]
        var current: [Int32: Reading] = [:]

        for pid in requested {
            var sample = ProcessSample()

            if let task = Self.taskInfo(pid) {
                sample.residentBytes = task.pti_resident_size
                sample.threads = Int(task.pti_threadnum)
            }

            if let bsd = Self.bsdInfo(pid) {
                sample.startedAt = Self.startDate(from: bsd)
            }

            if let usage = Self.resourceUsage(pid) {
                let reading = Reading(
                    cpuNanos: Self.nanoseconds(fromMachTicks: usage.ri_user_time &+ usage.ri_system_time),
                    energy: usage.ri_billed_energy,
                    wakeups: usage.ri_interrupt_wkups,
                    at: now
                )
                current[pid] = reading

                if let last = previous[pid] {
                    let elapsed = reading.at.timeIntervalSince(last.at)
                    let cpu = Self.cpuPercent(
                        cpuNanos: reading.cpuNanos,
                        previousCPUNanos: last.cpuNanos,
                        elapsed: elapsed
                    )

                    sample.cpuPercent = cpu
                    sample.energyLevel = Self.energyLevel(
                        cpuPercent: cpu,
                        billedDelta: Self.delta(reading.energy, last.energy),
                        wakeupsDelta: Self.delta(reading.wakeups, last.wakeups),
                        elapsed: elapsed
                    )
                }
            }

            samples[pid] = sample
        }

        // Drop state for pids we were not asked about, so a machine that has churned
        // through thousands of dev servers doesn't accumulate them for the session.
        previous = current
        return samples
    }

    /// Forgets every previous reading, so the next sample reports `nil` CPU again.
    func reset() {
        previous.removeAll()
    }

    // MARK: - Derivation

    /// Per-core-uncapped, exactly like Activity Monitor: a process saturating two cores
    /// reads 200%. Deliberately not clamped to 100.
    static func cpuPercent(cpuNanos: Double, previousCPUNanos: Double, elapsed: TimeInterval) -> Double? {
        guard elapsed > 0, cpuNanos >= previousCPUNanos else { return nil }

        let elapsedNanos = elapsed * 1_000_000_000
        return max(0, (cpuNanos - previousCPUNanos) / elapsedNanos * 100)
    }

    /// `ri_user_time` and `ri_system_time` are documented as nanoseconds but are actually
    /// mach absolute time units — verified against `getrusage` on this machine, where
    /// reading them as nanoseconds underreports CPU by 41.7x. The timebase is 1:1 on
    /// Intel, which is why the mistake survives so long in sample code.
    static func nanoseconds(fromMachTicks ticks: UInt64) -> Double {
        Double(ticks) * timebaseScale
    }

    private static let timebaseScale: Double = {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom > 0 else {
            return 1
        }

        return Double(timebase.numer) / Double(timebase.denom)
    }()

    /// Approximates Activity Monitor's "Energy Impact" — an unpublished blend that is
    /// mostly sustained CPU plus how often a process wakes the machine out of idle.
    ///
    /// CPU carries the ranking because it is the only term that reliably moves:
    /// `ri_billed_energy` measures work *billed to* a task by another process, and on
    /// Apple Silicon it stayed at 0 for every listener sampled here, including one pinned
    /// at 100%. It is still folded in for the machines where it is populated, and
    /// interrupt wakeups catch the low-CPU-but-always-poking case (an idle Docker backend
    /// wakes ~95 times a second while reading 0% CPU).
    ///
    /// Rates are per-second so the answer doesn't depend on the polling interval. This is
    /// a rank, not a physical unit — the boundaries are a UI affordance, not a measurement.
    static func energyLevel(
        cpuPercent: Double?,
        billedDelta: UInt64,
        wakeupsDelta: UInt64,
        elapsed: TimeInterval
    ) -> EnergyLevel {
        guard elapsed > 0 else { return .low }

        let cpu = cpuPercent ?? 0
        // Nanojoules per second → milliwatts.
        let milliwatts = Double(billedDelta) / elapsed / 1_000_000
        let wakeupsPerSecond = Double(wakeupsDelta) / elapsed

        if cpu >= 60 || wakeupsPerSecond >= 400 || milliwatts >= 250 { return .high }
        if cpu >= 10 || wakeupsPerSecond >= 50 || milliwatts >= 25 { return .medium }
        return .low
    }

    /// Counters can only move forward; anything else means the pid was recycled.
    static func delta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current > previous ? current - previous : 0
    }

    static func startDate(from bsd: proc_bsdinfo) -> Date? {
        guard bsd.pbi_start_tvsec > 0 else { return nil }

        let seconds = Double(bsd.pbi_start_tvsec) + Double(bsd.pbi_start_tvusec) / 1_000_000
        return Date(timeIntervalSince1970: seconds)
    }

    // MARK: - libproc

    /// `proc_pid_rusage` takes a `rusage_info_t?` out-parameter, which is a pointer to a
    /// pointer in Swift's rendering. Passing an uninitialised one crashes the process, so
    /// we allocate the concrete struct and rebind the pointer to it.
    static func resourceUsage(_ pid: Int32) -> rusage_info_v6? {
        var usage = rusage_info_v6()

        let result = withUnsafeMutablePointer(to: &usage) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V6, rebound)
            }
        }

        return result == 0 ? usage : nil
    }

    static func taskInfo(_ pid: Int32) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)

        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else {
            return nil
        }

        return info
    }

    static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)

        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return nil
        }

        return info
    }
}
