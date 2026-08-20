import XCTest
@testable import Seer

/// Exercises `NativeProcessSnapshotSource`'s stateful two-sample CPU-percent
/// math against a fully synthetic `ProcessBackend` double — this suite must
/// never enumerate real OS processes (see `FakeProcessBackend`).
final class ProcessSnapshotSourceTests: XCTestCase {
    private final class PIDEnumerationFixture: @unchecked Sendable {
        let pids: [pid_t]
        let returnedCount: Int32
        private(set) var sampledPIDs: [pid_t] = []

        init(pids: [pid_t], returnedCount: Int32? = nil) {
            self.pids = pids
            self.returnedCount = returnedCount ?? Int32(pids.count)
        }

        func list(into buffer: UnsafeMutableBufferPointer<pid_t>) -> Int32 {
            for (index, pid) in pids.prefix(buffer.count).enumerated() {
                buffer[index] = pid
            }
            return returnedCount
        }

        func sample(pid: pid_t) -> RawProcessSample? {
            sampledPIDs.append(pid)
            return RawProcessSample(
                pid: pid,
                command: "pid-\(pid)",
                cpuTimeNanoseconds: nil,
                identityToken: nil
            )
        }
    }

    private final class FakeProcessBackend: ProcessBackend, @unchecked Sendable {
        var samplesQueue: [[RawProcessSample]] = []
        var nowQueue: [UInt64] = []
        var ownPIDValue: Int32 = -1
        var enumerationError: Error?

        func monotonicNowNanoseconds() -> UInt64 {
            guard !nowQueue.isEmpty else { return 0 }
            return nowQueue.removeFirst()
        }

        func ownPID() -> Int32 { ownPIDValue }

        func sampleAll() throws -> [RawProcessSample] {
            if let enumerationError {
                throw enumerationError
            }
            guard !samplesQueue.isEmpty else { return [] }
            return samplesQueue.removeFirst()
        }
    }

    private func sample(pid: Int32, command: String, cpuTimeNs: UInt64?, identity: Int64? = 1) -> RawProcessSample {
        RawProcessSample(pid: pid, command: command, cpuTimeNanoseconds: cpuTimeNs, identityToken: identity)
    }

    // MARK: - libproc PID-count semantics

    func testLibProcBackendEnumeratesEveryReturnedPIDCount() throws {
        let fixture = PIDEnumerationFixture(pids: [11, 22, 33, 44])
        let backend = LibProcProcessBackend(
            maximumEnumeratedPIDs: 8,
            listAllPIDs: fixture.list,
            samplePID: fixture.sample
        )

        let samples = try backend.sampleAll()

        XCTAssertEqual(samples.map(\.pid), [11, 22, 33, 44])
        XCTAssertEqual(fixture.sampledPIDs, [11, 22, 33, 44])
    }

    func testLibProcBackendCapsReturnedPIDCountAtAllocatedCapacity() throws {
        let fixture = PIDEnumerationFixture(pids: [11, 22, 33], returnedCount: 99)
        let backend = LibProcProcessBackend(
            maximumEnumeratedPIDs: 3,
            listAllPIDs: fixture.list,
            samplePID: fixture.sample
        )

        let samples = try backend.sampleAll()

        XCTAssertEqual(samples.map(\.pid), [11, 22, 33])
        XCTAssertEqual(fixture.sampledPIDs, [11, 22, 33], "a kernel count larger than capacity must never index beyond the PID buffer")
    }

    func testLibProcBackendRejectsNonpositivePIDCount() {
        let fixture = PIDEnumerationFixture(pids: [], returnedCount: 0)
        let backend = LibProcProcessBackend(
            maximumEnumeratedPIDs: 3,
            listAllPIDs: fixture.list,
            samplePID: fixture.sample
        )

        XCTAssertThrowsError(try backend.sampleAll()) { error in
            guard case ProcessBackendError.enumerationFailed = error else {
                return XCTFail("expected enumeration failure, got \(error)")
            }
        }
        XCTAssertTrue(fixture.sampledPIDs.isEmpty)
    }

    // MARK: - First sample semantics

    func testFirstSampleReportsNilCPUPercent() async throws {
        let backend = FakeProcessBackend()
        backend.nowQueue = [1_000_000_000]
        backend.samplesQueue = [[sample(pid: 100, command: "codex", cpuTimeNs: 500_000_000)]]
        let source = NativeProcessSnapshotSource(backend: backend)

        let snapshots = try await source.snapshot()

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.pid, 100)
        XCTAssertNil(snapshots.first?.cpuPercent, "a lone first sample must never report a CPU percentage")
    }

    // MARK: - Second sample threshold behavior

    func testSecondSampleBelowThreshold() async throws {
        let backend = FakeProcessBackend()
        // One second of wall time; 24.9% of it spent on CPU => 249_000_000ns delta.
        backend.nowQueue = [0, 1_000_000_000]
        backend.samplesQueue = [
            [sample(pid: 100, command: "aider", cpuTimeNs: 0)],
            [sample(pid: 100, command: "aider", cpuTimeNs: 249_000_000)],
        ]
        let source = NativeProcessSnapshotSource(backend: backend)

        _ = try await source.snapshot()
        let second = try await source.snapshot()

        let cpu = try XCTUnwrap(second.first?.cpuPercent)
        XCTAssertEqual(cpu, 24.9, accuracy: 0.01)
        XCTAssertLessThan(cpu, 25.0)
    }

    func testSecondSampleAtThreshold() async throws {
        let backend = FakeProcessBackend()
        backend.nowQueue = [0, 1_000_000_000]
        backend.samplesQueue = [
            [sample(pid: 100, command: "aider", cpuTimeNs: 0)],
            [sample(pid: 100, command: "aider", cpuTimeNs: 250_000_000)],
        ]
        let source = NativeProcessSnapshotSource(backend: backend)

        _ = try await source.snapshot()
        let second = try await source.snapshot()

        let cpu = try XCTUnwrap(second.first?.cpuPercent)
        XCTAssertEqual(cpu, 25.0, accuracy: 0.001)
    }

    func testSecondSampleAboveThreshold() async throws {
        let backend = FakeProcessBackend()
        backend.nowQueue = [0, 1_000_000_000]
        backend.samplesQueue = [
            [sample(pid: 100, command: "aider", cpuTimeNs: 0)],
            [sample(pid: 100, command: "aider", cpuTimeNs: 251_000_000)],
        ]
        let source = NativeProcessSnapshotSource(backend: backend)

        _ = try await source.snapshot()
        let second = try await source.snapshot()

        let cpu = try XCTUnwrap(second.first?.cpuPercent)
        XCTAssertGreaterThan(cpu, 25.0)
    }

    // MARK: - Own PID exclusion

    func testOwnPIDIsExcludedFromSnapshot() async throws {
        let backend = FakeProcessBackend()
        backend.ownPIDValue = 999
        backend.nowQueue = [0]
        backend.samplesQueue = [[
            sample(pid: 999, command: "Seer", cpuTimeNs: 100),
            sample(pid: 100, command: "codex", cpuTimeNs: 100),
        ]]
        let source = NativeProcessSnapshotSource(backend: backend)

        let snapshots = try await source.snapshot()

        XCTAssertEqual(snapshots.map(\.pid), [100])
    }

    // MARK: - Process disappearance / PID reuse

    func testDisappearedProcessDoesNotPoisonReusedPID() async throws {
        let backend = FakeProcessBackend()
        backend.nowQueue = [0, 1_000_000_000, 2_000_000_000]
        backend.samplesQueue = [
            [sample(pid: 100, command: "codex", cpuTimeNs: 5_000_000_000, identity: 1)],
            [], // pid 100 disappears entirely for one scan
            [sample(pid: 100, command: "aider", cpuTimeNs: 10, identity: 2)], // reused, unrelated process
        ]
        let source = NativeProcessSnapshotSource(backend: backend)

        _ = try await source.snapshot()
        let afterDisappearance = try await source.snapshot()
        XCTAssertTrue(afterDisappearance.isEmpty)

        let reused = try await source.snapshot()
        XCTAssertEqual(reused.first?.command, "aider")
        XCTAssertNil(reused.first?.cpuPercent, "a pid that vanished and was reused must be treated as a fresh first sample")
    }

    func testPIDReuseWithDifferentIdentityResetsToFirstSample() async throws {
        let backend = FakeProcessBackend()
        backend.nowQueue = [0, 1_000_000_000]
        backend.samplesQueue = [
            [sample(pid: 100, command: "codex", cpuTimeNs: 9_000_000_000, identity: 1)],
            // Same pid, brand new (lower) cumulative CPU time and a
            // different identity token: a different process now occupies
            // pid 100, so this must not diff against the old baseline.
            [sample(pid: 100, command: "amp", cpuTimeNs: 5, identity: 2)],
        ]
        let source = NativeProcessSnapshotSource(backend: backend)

        _ = try await source.snapshot()
        let second = try await source.snapshot()

        XCTAssertEqual(second.first?.command, "amp")
        XCTAssertNil(second.first?.cpuPercent)
    }

    func testPIDReuseWithoutIdentityFallsBackToMonotonicityGuard() async throws {
        let backend = FakeProcessBackend()
        backend.nowQueue = [0, 1_000_000_000]
        backend.samplesQueue = [
            [sample(pid: 100, command: "codex", cpuTimeNs: 9_000_000_000, identity: nil)],
            // No identity available either time; cumulative time went
            // backwards, which must be treated as unusable rather than
            // producing a negative/garbage percentage.
            [sample(pid: 100, command: "codex", cpuTimeNs: 5, identity: nil)],
        ]
        let source = NativeProcessSnapshotSource(backend: backend)

        _ = try await source.snapshot()
        let second = try await source.snapshot()

        XCTAssertNil(second.first?.cpuPercent)
    }

    // MARK: - Bounds and rejected values

    func testZeroWallTimeDeltaProducesNilRatherThanInfinite() async throws {
        let backend = FakeProcessBackend()
        // Same monotonic timestamp reported twice (clock did not advance).
        backend.nowQueue = [1_000, 1_000]
        backend.samplesQueue = [
            [sample(pid: 100, command: "codex", cpuTimeNs: 0)],
            [sample(pid: 100, command: "codex", cpuTimeNs: 500)],
        ]
        let source = NativeProcessSnapshotSource(backend: backend)

        _ = try await source.snapshot()
        let second = try await source.snapshot()

        XCTAssertNil(second.first?.cpuPercent)
    }

    func testUnreadableRusageStillReportsProcessWithNilCPU() async throws {
        let backend = FakeProcessBackend()
        backend.nowQueue = [0]
        backend.samplesQueue = [[sample(pid: 100, command: "codex", cpuTimeNs: nil)]]
        let source = NativeProcessSnapshotSource(backend: backend)

        let snapshots = try await source.snapshot()

        XCTAssertEqual(snapshots.count, 1, "an unreadable process must still appear, not be dropped from the scan")
        XCTAssertNil(snapshots.first?.cpuPercent)
    }

    func testPathologicalCPUDeltaIsCappedNotRejected() async throws {
        let backend = FakeProcessBackend()
        backend.nowQueue = [0, 1_000_000] // 1ms wall time
        backend.samplesQueue = [
            [sample(pid: 100, command: "codex", cpuTimeNs: 0)],
            // Absurd cumulative delta relative to wall time (would compute
            // to a huge percentage without capping).
            [sample(pid: 100, command: "codex", cpuTimeNs: 1_000_000_000)],
        ]
        let source = NativeProcessSnapshotSource(backend: backend, maximumCPUPercent: 400)

        _ = try await source.snapshot()
        let second = try await source.snapshot()

        let cpu = try XCTUnwrap(second.first?.cpuPercent)
        XCTAssertEqual(cpu, 400, "pathological deltas must be capped at the documented ceiling, not silently rejected")
    }

    func testBackendEnumerationFailurePropagates() async throws {
        let backend = FakeProcessBackend()
        backend.nowQueue = [0]
        backend.enumerationError = ProcessBackendError.enumerationFailed("boom")
        let source = NativeProcessSnapshotSource(backend: backend)

        do {
            _ = try await source.snapshot()
            XCTFail("expected enumeration failure to propagate")
        } catch ProcessBackendError.enumerationFailed {
            // expected
        }
    }
}
