import Darwin
import Foundation

/// One observed OS process relevant to agent detection: its pid, full
/// command line (used for family matching against `matchAgentKind`), and a
/// CPU utilization percentage computed from two time-separated samples of
/// cumulative CPU time.
///
/// `cpuPercent` is `nil` whenever a usable percentage cannot yet be
/// computed — most notably on a process's very first observed sample, since
/// a single point-in-time reading of cumulative CPU time cannot express
/// "percent of wall time spent using the CPU" without a prior baseline.
/// Callers (see `AgentDetector`) must never treat a `nil` `cpuPercent` as
/// zero-and-therefore-inactive vs. active — it specifically means "unknown
/// yet," so process-only activity fallback must require a non-nil value.
public struct ProcessSnapshot: Equatable, Sendable {
    public let pid: Int32
    public let command: String
    public let cpuPercent: Double?

    public init(pid: Int32, command: String, cpuPercent: Double? = nil) {
        self.pid = pid
        self.command = command
        self.cpuPercent = cpuPercent
    }
}

/// Injectable source of process snapshots. Production code is
/// `NativeProcessSnapshotSource`, backed by `LibProcProcessBackend`; tests
/// substitute a stub/fake that never enumerates real OS processes.
public protocol ProcessSnapshotProviding: Sendable {
    func snapshot() async throws -> [ProcessSnapshot]
}

/// One raw process reading pulled directly from a `ProcessBackend`, prior to
/// any stateful CPU-percent calculation. Kept separate from `ProcessSnapshot`
/// because the backend only ever reports point-in-time cumulative facts —
/// the percent-of-wall-time math is `NativeProcessSnapshotSource`'s job, not
/// the backend's, so backend implementations stay simple and the math stays
/// unit-testable against synthetic samples.
public struct RawProcessSample: Equatable, Sendable {
    public let pid: Int32
    public let command: String
    /// Cumulative user+system CPU time consumed by the process, in
    /// nanoseconds, since process start. `nil` when the backend could not
    /// read resource usage for this pid (e.g. permission denied, or the
    /// process exited between enumeration and the rusage read) — such
    /// processes are still reported (with a `nil` value here, which flows
    /// through to a `nil` `cpuPercent`) rather than dropped outright, so a
    /// single unreadable process never removes an otherwise-matched agent
    /// process from consideration.
    public let cpuTimeNanoseconds: UInt64?
    /// A best-effort identity token distinguishing this pid's current
    /// occupant from a prior, unrelated process that reused the same pid
    /// (e.g. the process start time). `nil` when unavailable, in which case
    /// PID-reuse detection falls back to cumulative-CPU-time monotonicity
    /// alone (see `NativeProcessSnapshotSource`).
    public let identityToken: Int64?

    public init(pid: Int32, command: String, cpuTimeNanoseconds: UInt64?, identityToken: Int64?) {
        self.pid = pid
        self.command = command
        self.cpuTimeNanoseconds = cpuTimeNanoseconds
        self.identityToken = identityToken
    }
}

/// Abstraction over the actual OS process enumeration + resource-usage
/// sampling, so `NativeProcessSnapshotSource`'s stateful CPU-percent math can
/// be exercised in tests against fully synthetic samples without ever
/// enumerating real OS processes. `LibProcProcessBackend` is the only
/// conformer permitted to call `proc_listallpids`/`sysctl`/`proc_pid_rusage`
/// — production code never shells out to `/bin/ps` or any other subprocess.
public protocol ProcessBackend: Sendable {
    /// The current instant, in nanoseconds, from a monotonic clock (never
    /// affected by wall-clock adjustments like NTP steps or DST). Used only
    /// to normalize CPU time deltas against elapsed wall time.
    func monotonicNowNanoseconds() -> UInt64
    /// Every currently-visible process's raw sample, in the backend's
    /// natural enumeration order. Implementations must bound both the
    /// number of processes enumerated and the length of any command string
    /// returned, and must tolerate individual processes disappearing or
    /// denying access mid-scan without failing the whole call.
    func sampleAll() throws -> [RawProcessSample]
    /// This process's own pid, so callers can exclude Seer itself from the
    /// resulting snapshots.
    func ownPID() -> Int32
}

/// Errors a `ProcessBackend` may throw for a scan-wide (not per-process)
/// failure — e.g. the OS refused to enumerate processes at all.
public enum ProcessBackendError: Error, Equatable, Sendable {
    case enumerationFailed(String)
}

/// Production `ProcessBackend`, backed entirely by native Darwin APIs:
/// `proc_listallpids` for enumeration, `proc_pidpath` for each process's
/// executable identity/path (the plan's required primary identity check —
/// a pid whose path cannot be resolved, e.g. because it already exited or
/// the kernel denies the query, is skipped outright), `sysctl
/// (KERN_PROCARGS2)` for the full command line as a bounded, best-effort
/// *addition* used only to reveal argument-level matches (scoped npm
/// package names, `--agent` flags) that a bare executable path can't
/// express, `proc_pid_rusage` for cumulative CPU time, and `proc_pidinfo`
/// (`PROC_PIDTBSDINFO`) for a process-start-time identity token used for
/// best-effort PID-reuse detection. Never invokes a shell or any
/// subprocess.
public struct LibProcProcessBackend: ProcessBackend {
    /// Upper bound on how many pids a single `sampleAll()` call will
    /// enumerate, defending against a pathologically large process table
    /// (e.g. a fork bomb) consuming unbounded memory/time.
    public static let maximumEnumeratedPIDs = 8192
    /// Upper bound on the length of any single command string returned,
    /// matching `sysctl`'s own bounded `ARG_MAX`-scale buffers but adding an
    /// explicit ceiling so a pathological argv can't produce unbounded
    /// `String` allocations downstream.
    public static let maximumCommandLength = 4096

    private let maximumPIDs: Int
    private let listAllPIDs: @Sendable (UnsafeMutableBufferPointer<pid_t>) -> Int32
    private let samplePID: @Sendable (pid_t) -> RawProcessSample?

    public init() {
        maximumPIDs = Self.maximumEnumeratedPIDs
        listAllPIDs = { buffer in
            guard let baseAddress = buffer.baseAddress else { return 0 }
            return proc_listallpids(
                baseAddress,
                Int32(buffer.count * MemoryLayout<pid_t>.size)
            )
        }
        samplePID = { pid in
            guard let executablePath = Self.executablePath(for: pid) else { return nil }
            return RawProcessSample(
                pid: pid,
                command: Self.commandLine(for: pid, executablePath: executablePath),
                cpuTimeNanoseconds: Self.cumulativeCPUTimeNanoseconds(for: pid),
                identityToken: Self.startTimeIdentityToken(for: pid)
            )
        }
    }

    init(
        maximumEnumeratedPIDs: Int,
        listAllPIDs: @escaping @Sendable (UnsafeMutableBufferPointer<pid_t>) -> Int32,
        samplePID: @escaping @Sendable (pid_t) -> RawProcessSample?
    ) {
        maximumPIDs = max(0, min(maximumEnumeratedPIDs, Self.maximumEnumeratedPIDs))
        self.listAllPIDs = listAllPIDs
        self.samplePID = samplePID
    }

    public func monotonicNowNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    public func ownPID() -> Int32 {
        getpid()
    }

    public func sampleAll() throws -> [RawProcessSample] {
        var pids = [pid_t](repeating: 0, count: maximumPIDs)
        let returnedCount = pids.withUnsafeMutableBufferPointer { buffer in
            listAllPIDs(buffer)
        }
        guard returnedCount > 0 else {
            throw ProcessBackendError.enumerationFailed("proc_listallpids failed (errno \(errno))")
        }

        let count = min(Int(returnedCount), pids.count)
        var samples: [RawProcessSample] = []
        samples.reserveCapacity(count)

        for index in 0..<count {
            // Defense-in-depth only: does not by itself guarantee a prompt
            // `AgentMonitor.stop()` return (`stop()` never awaits this
            // task's cooperation), but lets a cancelled scan unwind mid
            // enumeration instead of always walking the full pid table.
            try Task.checkCancellation()
            let pid = pids[index]
            guard pid > 0 else { continue }
            // A process that disappears or denies access between
            // enumeration and these per-pid reads is skipped, not treated
            // as a scan failure. `proc_pidpath` is the required primary
            // identity check: no resolvable executable path means no
            // usable sample for this pid.
            guard let sample = samplePID(pid) else { continue }
            samples.append(sample)
        }

        return samples
    }

    /// Reads the process's executable path via `proc_pidpath`. Returns
    /// `nil` if the kernel denies the query (e.g. a process owned by
    /// another user) or the process has already exited — both are
    /// ordinary, expected outcomes, never a thrown error.
    private static func executablePath(for pid: pid_t) -> String? {
        // `PROC_PIDPATHINFO_MAXSIZE` is a C macro (`4 * MAXPATHLEN`) that
        // isn't imported as a Swift constant; its defining formula is
        // stable ABI (see `<sys/proc_info.h>`), so it is reproduced
        // directly rather than hardcoding an unexplained buffer size.
        var buffer = [UInt8](repeating: 0, count: Int(4 * MAXPATHLEN))
        let bufferCount = buffer.count
        let length = buffer.withUnsafeMutableBytes { pointer -> Int32 in
            guard let base = pointer.baseAddress else { return -1 }
            return proc_pidpath(pid, base, UInt32(bufferCount))
        }
        guard length > 0 else { return nil }
        return String(decoding: buffer[0..<Int(length)], as: UTF8.self)
    }

    /// Builds the bounded command string used for family matching: the
    /// `proc_pidpath`-derived executable path, augmented with the full
    /// `argv` (via `sysctl(CTL_KERN, KERN_PROCARGS2, pid)`) when the kernel
    /// makes it available. `argv` alone can't always be trusted (e.g.
    /// `argv[0]` may be a relative/renamed name), so the executable path
    /// leads and the arguments are appended — this reveals argument-level
    /// matches (scoped npm package names, `--agent` flags) that the path
    /// alone would miss, without ever replacing the required
    /// `proc_pidpath` identity read above.
    private static func commandLine(for pid: pid_t, executablePath: String) -> String {
        guard let args = fullArguments(for: pid), !args.isEmpty else {
            return bounded(executablePath)
        }
        let joined = args.joined(separator: " ")
        // Skip a redundant argv[0] that merely repeats the executable path.
        let combined = joined == executablePath ? executablePath : "\(executablePath) \(joined)"
        return bounded(combined)
    }

    private static func bounded(_ text: String) -> String {
        guard text.count > maximumCommandLength else { return text }
        return String(text.prefix(maximumCommandLength))
    }

    /// Reads the full command line (`argv`, joined with spaces) via
    /// `sysctl(CTL_KERN, KERN_PROCARGS2, pid)`. Returns `nil` if the kernel
    /// denies the query (e.g. a process owned by another user), the
    /// process has already exited, or no arguments are available — all
    /// ordinary, expected outcomes. This is a bounded, best-effort
    /// *supplement* to `executablePath(for:)`, never a replacement for it.
    private static func fullArguments(for pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }

        // Small slack for a benign race where argv grows between the size
        // probe and the data read.
        let boundedSize = min(size + 4096, maximumCommandLength * 4)
        var buffer = [UInt8](repeating: 0, count: boundedSize)
        var actualSize = boundedSize
        let readRC = buffer.withUnsafeMutableBytes { pointer -> Int32 in
            sysctl(&mib, UInt32(mib.count), pointer.baseAddress, &actualSize, nil, 0)
        }
        guard readRC == 0, actualSize >= MemoryLayout<Int32>.size else { return nil }
        buffer.removeSubrange(actualSize..<buffer.count)

        let argc: Int32 = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        guard argc > 0 else { return nil }

        // Layout: argc (Int32), then the exec path (NUL-terminated), then
        // NUL padding, then argv[0]..argv[argc-1] (each NUL-terminated).
        var offset = MemoryLayout<Int32>.size
        while offset < buffer.count, buffer[offset] != 0 { offset += 1 }
        while offset < buffer.count, buffer[offset] == 0 { offset += 1 }

        var args: [String] = []
        var remaining = Int(argc)
        var index = offset
        while index < buffer.count, remaining > 0 {
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            guard index > start else { break }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            remaining -= 1
            index += 1
        }

        return args.isEmpty ? nil : args
    }

    /// Reads cumulative user+system CPU time via `proc_pid_rusage`
    /// (`RUSAGE_INFO_CURRENT`). Returns `nil` on permission denial or if the
    /// process has already exited. Uses reporting-overflow addition (never
    /// `&+`) even though these are kernel-sourced `UInt64` counters,
    /// because they are still an untrusted external input this process
    /// does not control — an overflow here saturates to `UInt64.max`
    /// rather than silently wrapping to a small, misleadingly "idle" value.
    private static func cumulativeCPUTimeNanoseconds(for pid: pid_t) -> UInt64? {
        var usage = rusage_info_current()
        let rc = withUnsafeMutablePointer(to: &usage) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rebound)
            }
        }
        guard rc == 0 else { return nil }
        let (sum, overflow) = usage.ri_user_time.addingReportingOverflow(usage.ri_system_time)
        return overflow ? UInt64.max : sum
    }

    /// Reads the process start time via `proc_pidinfo(PROC_PIDTBSDINFO)` and
    /// folds it into a single nanosecond-scale `Int64` identity token.
    /// Returns `nil` if the kernel denies the query or the process has
    /// already exited — best-effort only, per `RawProcessSample.identityToken`.
    /// Uses reporting-overflow arithmetic (never `&*`/`&+`) so a
    /// pathological/garbage kernel-reported timestamp saturates instead of
    /// silently wrapping into an unrelated, colliding identity token.
    private static func startTimeIdentityToken(for pid: pid_t) -> Int64? {
        var info = proc_bsdinfo()
        let size = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(MemoryLayout<proc_bsdinfo>.size))
        }
        guard size == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        let seconds = Int64(info.pbi_start_tvsec)
        let micros = Int64(info.pbi_start_tvusec)
        let (scaled, multiplyOverflow) = seconds.multipliedReportingOverflow(by: 1_000_000)
        guard !multiplyOverflow else { return seconds < 0 ? Int64.min : Int64.max }
        let (total, addOverflow) = scaled.addingReportingOverflow(micros)
        guard !addOverflow else { return scaled < 0 ? Int64.min : Int64.max }
        return total
    }
}

/// Stateful, two-sample CPU-percent calculator sitting in front of a
/// `ProcessBackend`. An `actor` because it must serialize access to its
/// per-pid sample history across concurrent scans (the detector/monitor
/// never overlap scans by contract, but the type itself stays safe even if
/// called concurrently for any reason).
///
/// CPU percent is computed as `(cumulative CPU time delta / wall time
/// delta) * 100` across exactly two samples of the same pid — never from a
/// single instantaneous reading, since cumulative CPU time alone says
/// nothing about a rate. A process's first observed sample therefore always
/// reports `cpuPercent == nil`; only a *second* sample of the same,
/// still-identified process can produce a percentage. This directly
/// satisfies the "first sample cannot trigger process-only activity"
/// requirement in `AgentDetector`'s process-only fallback.
public actor NativeProcessSnapshotSource: ProcessSnapshotProviding {
    /// Bounds how many pids' CPU history this source retains between scans,
    /// defending against unbounded memory growth from a pathologically
    /// large or churning process table.
    public static let maximumTrackedPIDs = 8192

    private struct Sample {
        let atNanoseconds: UInt64
        let cpuTimeNanoseconds: UInt64
        let identityToken: Int64?
    }

    private let backend: ProcessBackend
    /// The maximum CPU percentage this source will ever report — multi-core
    /// systems can genuinely exceed 100% (a process using 2 full cores
    /// reports ~200%), so the cap tracks the number of logical processors
    /// rather than a fixed 100%. Purely a defensive ceiling against
    /// pathological/garbage deltas; documented behavior, not a silent
    /// truncation of legitimate multi-core readings under normal
    /// conditions on the vast majority of hardware.
    private let maximumCPUPercent: Double

    private var lastSamples: [Int32: Sample] = [:]

    public init(backend: ProcessBackend, maximumCPUPercent: Double? = nil) {
        self.backend = backend
        if let maximumCPUPercent {
            self.maximumCPUPercent = maximumCPUPercent
        } else {
            let processors = max(1, ProcessInfo.processInfo.activeProcessorCount)
            self.maximumCPUPercent = Double(processors) * 100.0
        }
    }

    public func snapshot() async throws -> [ProcessSnapshot] {
        let now = backend.monotonicNowNanoseconds()
        let ownPID = backend.ownPID()
        let raws = try backend.sampleAll()

        var seenPIDs = Set<Int32>()
        var results: [ProcessSnapshot] = []
        results.reserveCapacity(min(raws.count, Self.maximumTrackedPIDs))

        for raw in raws {
            // Defense-in-depth only: does not by itself guarantee a prompt
            // `AgentMonitor.stop()` return (`stop()` never awaits this
            // task's cooperation), but lets a cancelled scan unwind mid
            // process-table walk instead of always finishing it.
            try Task.checkCancellation()
            if raw.pid == ownPID { continue }
            guard results.count < Self.maximumTrackedPIDs else { break }
            seenPIDs.insert(raw.pid)

            let cpuPercent = computeCPUPercent(for: raw, now: now)
            results.append(ProcessSnapshot(pid: raw.pid, command: raw.command, cpuPercent: cpuPercent))
        }

        // Drop history for pids no longer observed, so a pid that
        // disappears and later gets reused by an unrelated process starts
        // fresh (first-sample semantics) instead of being compared against
        // a stale, unrelated baseline.
        if !lastSamples.isEmpty {
            lastSamples = lastSamples.filter { seenPIDs.contains($0.key) }
        }

        return results
    }

    private func computeCPUPercent(for raw: RawProcessSample, now: UInt64) -> Double? {
        guard let cpuTime = raw.cpuTimeNanoseconds else {
            // No usable rusage this round — drop any stale baseline so a
            // later readable sample starts over as a fresh first sample
            // rather than comparing across a gap of unknown length.
            lastSamples.removeValue(forKey: raw.pid)
            return nil
        }

        defer {
            lastSamples[raw.pid] = Sample(atNanoseconds: now, cpuTimeNanoseconds: cpuTime, identityToken: raw.identityToken)
        }

        guard let previous = lastSamples[raw.pid] else {
            // First sample for this pid: no baseline to diff against.
            return nil
        }

        // Best-effort PID-reuse guard: if both samples carry an identity
        // token and they disagree, this pid was recycled by a different
        // process since the last sample — treat as a fresh first sample.
        if let previousToken = previous.identityToken, let currentToken = raw.identityToken, previousToken != currentToken {
            return nil
        }

        guard now > previous.atNanoseconds, cpuTime >= previous.cpuTimeNanoseconds else {
            // Non-positive wall-time delta, or cumulative CPU time went
            // backwards (e.g. an unidentifiable pid reuse) — neither can
            // produce a meaningful rate, so report unknown rather than a
            // nonsensical negative/undefined percentage.
            return nil
        }

        let deltaCPU = Double(cpuTime - previous.cpuTimeNanoseconds)
        let deltaWall = Double(now - previous.atNanoseconds)
        let rawPercent = (deltaCPU / deltaWall) * 100.0

        guard rawPercent.isFinite, rawPercent >= 0 else { return nil }
        return min(rawPercent, maximumCPUPercent)
    }
}
