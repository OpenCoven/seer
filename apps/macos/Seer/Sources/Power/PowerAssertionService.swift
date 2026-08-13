import Foundation
#if canImport(IOKit)
import IOKit
import IOKit.pwr_mgt
#endif

/// The human-readable reason string every Seer power assertion is created
/// with — exactly what `pmset -g assertions` or Activity Monitor's "Prevent
/// Sleep" inspector displays for the assertion. Kept as a single named
/// constant so production code and tests can never drift from each other.
public enum PowerAssertionReason {
    public static let stable = "Seer is keeping this Mac awake for an active AI coding agent."
}

/// Diagnostic ids `AppSnapshotCoordinator` publishes when a
/// `PowerAssertionService` call fails. Declared here (not in
/// `AppSnapshotCoordinator.swift`) because it is specifically the power
/// domain's own stable id, mirroring how `AgentMonitorDiagnosticID` lives
/// beside `AgentMonitor`.
public enum PowerDiagnosticID {
    public static let assertionFailed = "power.assertion.failed"
}

/// The system boundary `PowerAssertionService` depends on for creating and
/// releasing exactly one IOKit power assertion at a time. Injected so
/// tests never invoke a real IOKit call — a genuine
/// `IOPMAssertionCreateWithName` call would actually prevent the test
/// machine from idle-sleeping for as long as the assertion stayed alive,
/// which must never happen in a test process.
public protocol PowerAssertionBackend: Sendable {
    /// Creates a new assertion preventing idle sleep per `mode`, named
    /// `reason`. Returns the new assertion's nonzero id on success.
    func createAssertion(mode: KeepAwakeMode, reason: String) throws -> UInt32

    /// Releases a previously created assertion.
    func releaseAssertion(id: UInt32) throws
}

/// Failures either `PowerAssertionBackend` operation can report.
public enum PowerAssertionBackendError: Error, Equatable, Sendable {
    /// `IOPMAssertionCreateWithName` returned something other than
    /// `kIOReturnSuccess`, or returned success with a zero assertion id
    /// (which IOKit never legitimately assigns to a real assertion).
    case createFailed(ioReturnCode: Int32)
    /// `IOPMAssertionRelease` returned something other than
    /// `kIOReturnSuccess`.
    case releaseFailed(ioReturnCode: Int32)
    /// `PowerAssertionBackend`'s protocol declares plain, untyped
    /// `throws` — nothing prevents a conformance (a test double, or a
    /// future non-IOKit backend) from throwing some entirely different
    /// `Error` type instead of one of this enum's own cases.
    /// `PowerAssertionService` normalizes any such foreign error into
    /// this case (via `String(describing:)`, so the message stays
    /// human-readable) rather than letting it escape uncaught and skip
    /// every compensating rollback below.
    case foreign(description: String)
}

#if canImport(IOKit)
/// Production `PowerAssertionBackend`, backed directly by
/// `IOPMAssertionCreateWithName`/`IOPMAssertionRelease`. Never constructed
/// by any test — see `PowerAssertionBackend`'s documentation.
public struct IOKitPowerAssertionBackend: PowerAssertionBackend {
    public init() {}

    public func createAssertion(mode: KeepAwakeMode, reason: String) throws -> UInt32 {
        var assertionID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            Self.ioKitAssertionType(for: mode) as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        guard result == kIOReturnSuccess, assertionID != 0 else {
            throw PowerAssertionBackendError.createFailed(ioReturnCode: result)
        }
        return UInt32(assertionID)
    }

    public func releaseAssertion(id: UInt32) throws {
        let result = IOPMAssertionRelease(IOPMAssertionID(id))
        guard result == kIOReturnSuccess else {
            throw PowerAssertionBackendError.releaseFailed(ioReturnCode: result)
        }
    }

    /// Maps `KeepAwakeMode` to the exact IOKit assertion type it prevents:
    /// `.system` prevents idle *system* sleep only; `.display` prevents
    /// idle *display* sleep, which — per IOKit's documented behavior —
    /// transitively keeps the system awake too while the display stays
    /// lit.
    private static func ioKitAssertionType(for mode: KeepAwakeMode) -> String {
        switch mode {
        case .system:
            return kIOPMAssertionTypePreventUserIdleSystemSleep as String
        case .display:
            return kIOPMAssertionTypePreventUserIdleDisplaySleep as String
        }
    }
}
#endif

/// Typed failures `PowerAssertionService.setDesired(active:mode:)` (and
/// `shutdown()`) can throw. Every case carries the service's exact actual
/// post-call state (`actualAssertionID`/`actualMode`) so a caller never has
/// to guess whether "throw" means "nothing changed" — see each case's
/// documentation for precisely what it means.
public enum PowerAssertionServiceError: Error, Equatable, Sendable {
    /// No assertion was active before the call; creating the requested one
    /// failed. The service remains fully inactive (no
    /// `actualAssertionID`/`actualMode` — there is nothing to report).
    case creationFailed(underlying: PowerAssertionBackendError)

    /// An assertion was active and the caller asked to deactivate; the
    /// release failed. The service conservatively continues reporting the
    /// original assertion active — a failed release is never assumed to
    /// have actually released anything.
    case releaseFailed(underlying: PowerAssertionBackendError, actualAssertionID: UInt32, actualMode: KeepAwakeMode)

    /// A mode replacement's *new* assertion could not be created. The
    /// original assertion was never touched by this call and remains the
    /// sole active one.
    case replacementCreationFailed(underlying: PowerAssertionBackendError, actualAssertionID: UInt32, actualMode: KeepAwakeMode)

    /// A mode replacement created its new assertion successfully, but
    /// releasing the original one then failed. The service compensates by
    /// releasing the just-created replacement (rolling the transition
    /// back), so the original assertion remains the sole active one —
    /// exactly as before this call.
    case replacementRolledBack(underlying: PowerAssertionBackendError, actualAssertionID: UInt32, actualMode: KeepAwakeMode)

    /// A mode replacement created its new assertion successfully, the old
    /// release failed, *and* the compensating rollback release of the new
    /// assertion also failed. Both assertions may still be alive at the OS
    /// level — a double-live-assertion condition this service cannot
    /// silently resolve on its own. It pins its reported state to the
    /// *new* assertion (`actualAssertionID`/`actualMode`, known to have
    /// been created successfully) rather than the old one, and
    /// `leakedAssertionID` names the old assertion that could not be
    /// confirmed released, so a caller can still surface the leak instead
    /// of silently losing track of it.
    case replacementRollbackFailed(
        oldReleaseUnderlying: PowerAssertionBackendError,
        rollbackReleaseUnderlying: PowerAssertionBackendError,
        leakedAssertionID: UInt32,
        actualAssertionID: UInt32,
        actualMode: KeepAwakeMode
    )
}

/// Owns exactly zero or one active IOKit power assertion at a time.
///
/// `@MainActor` to match `AppSnapshotCoordinator`'s isolation. Every method
/// here is synchronous — the underlying IOKit calls this wraps are
/// themselves synchronous — so no `await` is ever needed at a call site
/// already running on the main actor.
///
/// `setDesired(active:mode:)` is the single entry point for every state
/// change; see `PowerAssertionServiceError` for the exact compensating
/// behavior when a mode replacement partially fails. `shutdown()` is the
/// sole authoritative release path during app termination; `deinit` only
/// best-effort releases as a safety net for a caller that forgot to call
/// it.
@MainActor
public final class PowerAssertionService {
    private let backend: any PowerAssertionBackend
    private let reason: String

    /// The currently active assertion's id, or `nil` if none is active.
    public private(set) var activeAssertionID: UInt32?
    /// The mode the currently active assertion was created with, or `nil`
    /// if none is active.
    public private(set) var activeMode: KeepAwakeMode?

    /// Whether an assertion is currently active. Exactly
    /// `activeAssertionID != nil`.
    public var isActive: Bool { activeAssertionID != nil }

    public init(backend: any PowerAssertionBackend, reason: String = PowerAssertionReason.stable) {
        self.backend = backend
        self.reason = reason
    }

    /// Applies one desired-state transition atomically:
    /// - `active: false` releases the active assertion, if any (idempotent
    ///   if already inactive).
    /// - `active: true` with no assertion currently active creates one.
    /// - `active: true` with an assertion already active in the same
    ///   `mode` is a no-op (idempotent, no backend calls at all).
    /// - `active: true` with an assertion active in a *different* `mode`
    ///   replaces it: creates the new assertion first, then releases the
    ///   old one — see `PowerAssertionServiceError` for what happens (and
    ///   what is reported) if either step fails.
    ///
    /// Returns whether the backend was actually invoked (`false` for every
    /// idempotent no-op).
    @discardableResult
    public func setDesired(active: Bool, mode: KeepAwakeMode) throws -> Bool {
        guard active else {
            return try deactivate()
        }
        guard let currentID = activeAssertionID, let currentMode = activeMode else {
            return try activateFresh(mode: mode)
        }
        guard currentMode != mode else {
            return false
        }
        return try replace(withMode: mode, oldID: currentID, oldMode: currentMode)
    }

    private func deactivate() throws -> Bool {
        guard let id = activeAssertionID, let mode = activeMode else {
            return false
        }
        do {
            try backend.releaseAssertion(id: id)
        } catch {
            // Do not clear state: a failed release is never assumed to
            // have actually released the assertion. Caught as `any
            // Error` (not just `PowerAssertionBackendError`) because the
            // protocol's untyped `throws` permits a conformance to throw
            // anything; `Self.normalize(_:)` still surfaces it as a
            // stable, typed underlying error.
            throw PowerAssertionServiceError.releaseFailed(
                underlying: Self.normalize(error),
                actualAssertionID: id,
                actualMode: mode
            )
        }
        activeAssertionID = nil
        activeMode = nil
        return true
    }

    private func activateFresh(mode: KeepAwakeMode) throws -> Bool {
        do {
            let id = try backend.createAssertion(mode: mode, reason: reason)
            activeAssertionID = id
            activeMode = mode
            return true
        } catch {
            throw PowerAssertionServiceError.creationFailed(underlying: Self.normalize(error))
        }
    }

    private func replace(withMode mode: KeepAwakeMode, oldID: UInt32, oldMode: KeepAwakeMode) throws -> Bool {
        let newID: UInt32
        do {
            newID = try backend.createAssertion(mode: mode, reason: reason)
        } catch {
            // Old assertion was never touched: it remains the sole active
            // one, exactly as before this call.
            throw PowerAssertionServiceError.replacementCreationFailed(
                underlying: Self.normalize(error),
                actualAssertionID: oldID,
                actualMode: oldMode
            )
        }

        do {
            try backend.releaseAssertion(id: oldID)
        } catch {
            // Caught as `any Error`, not just `PowerAssertionBackendError`
            // — a foreign error thrown here must still trigger the
            // compensating rollback below rather than escaping uncaught
            // and leaving the just-created replacement's fate (and the
            // old assertion's) unattempted.
            let releaseError = Self.normalize(error)
            // Compensate: roll back by releasing the just-created
            // replacement, so the old assertion remains the sole active
            // one — never permit two silently-live ids.
            do {
                try backend.releaseAssertion(id: newID)
            } catch {
                // Both releases failed: both assertions may still be
                // alive at the OS level. Pin reported state to the newly
                // created assertion (confirmed created) and surface the
                // leaked old id rather than silently dropping it.
                let rollbackError = Self.normalize(error)
                activeAssertionID = newID
                activeMode = mode
                throw PowerAssertionServiceError.replacementRollbackFailed(
                    oldReleaseUnderlying: releaseError,
                    rollbackReleaseUnderlying: rollbackError,
                    leakedAssertionID: oldID,
                    actualAssertionID: newID,
                    actualMode: mode
                )
            }
            // Rollback succeeded: state reverts to exactly what it was
            // before this call.
            throw PowerAssertionServiceError.replacementRolledBack(
                underlying: releaseError,
                actualAssertionID: oldID,
                actualMode: oldMode
            )
        }

        activeAssertionID = newID
        activeMode = mode
        return true
    }

    /// Normalizes any error a `PowerAssertionBackend` conformance throws
    /// into a `PowerAssertionBackendError`: passes an already-typed one
    /// through unchanged, or wraps any foreign error (permitted by the
    /// protocol's untyped `throws`) into `.foreign`, preserving its
    /// readable description. The single place every compensation path
    /// above relies on to keep `PowerAssertionServiceError`'s underlying
    /// error stable and typed regardless of what the backend actually
    /// threw.
    private static func normalize(_ error: Error) -> PowerAssertionBackendError {
        (error as? PowerAssertionBackendError) ?? .foreign(description: String(describing: error))
    }

    /// Releases the active assertion (if any) — the exact same path as
    /// `setDesired(active: false, mode:)`. Idempotent: calling this again
    /// after a successful shutdown, or when no assertion was ever created,
    /// is a no-op. This is the authoritative release path
    /// `AppSnapshotCoordinator` awaits during app termination; a release
    /// failure is thrown, never swallowed.
    public func shutdown() throws {
        _ = try deactivate()
    }

    deinit {
        // Best-effort only: `deinit` cannot throw or let any caller react
        // to a failed release. Explicit `shutdown()` remains the sole
        // authoritative release path; this is purely a safety net against
        // a caller that forgot to call it.
        if let id = activeAssertionID {
            try? backend.releaseAssertion(id: id)
        }
    }
}
