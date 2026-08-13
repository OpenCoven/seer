import Foundation
import WebKit

/// Outcome of a bridge command that returns a fresh `AppSnapshot` on
/// success (`snapshot.get`, `keepAwakeMode.set`, `history.clear`,
/// `updates.check`) — matching `BridgeMethodResultMap` in the TS source.
public typealias BridgeSnapshotOutcome = Result<AppSnapshot, BridgeCommandError>

/// Outcome of a bridge command with no result payload on success
/// (`updates.open`, `app.quit`, `panel.hide`) — wire-encoded as
/// `result: null`.
public typealias BridgeVoidOutcome = Result<Void, BridgeCommandError>

/// A sanitized, typed error a `BridgeCommandHandling` implementation can
/// report. `message` must never leak internal file paths, stack traces, or
/// other implementation detail.
public struct BridgeCommandError: Error, Equatable, Sendable {
    public let code: BridgeErrorCode
    public let message: String

    public init(code: BridgeErrorCode, message: String) {
        self.code = code
        self.message = message
    }

    /// The standard error every not-yet-implemented command (Task 11's
    /// update check/open, Task 12's panel/app lifecycle) reports until a
    /// real runtime implementation is injected. Never a fake success.
    public static let unavailable = BridgeCommandError(
        code: .commandUnavailable,
        message: "This command is not available in this build"
    )
}

/// Typed, closed surface every bridge command routes through. One method
/// per `BridgeMethod` case — there is deliberately no generic
/// `execute(method:payload:)` (or URL/command-string) escape hatch, so a
/// new command can never be wired up, nor an existing one bypassed, other
/// than through one of these exact typed methods.
@MainActor
public protocol BridgeCommandHandling {
    func snapshotGet() async -> BridgeSnapshotOutcome
    func keepAwakeModeSet(_ mode: KeepAwakeMode) async -> BridgeSnapshotOutcome
    func historyClear() async -> BridgeSnapshotOutcome
    func updatesCheck() async -> BridgeSnapshotOutcome
    func updatesOpen() async -> BridgeVoidOutcome
    func panelHide() async -> BridgeVoidOutcome
    func appQuit() async -> BridgeVoidOutcome
}

/// The concrete `BridgeCommandHandling` used by the standalone app. Every
/// command is an independently injected closure rather than a direct
/// dependency on any particular service type. `forCoordinator(_:)` wires up
/// the three commands Task 9's `AppSnapshotCoordinator` already implements;
/// `updatesCheck`/`updatesOpen`/`panelHide`/`appQuit` default to
/// `.unavailable` stubs until Task 11/12 inject their real
/// implementations — this router never fakes a success for a command it
/// cannot actually perform.
@MainActor
public final class StandaloneBridgeCommandRouter: BridgeCommandHandling {
    private let snapshotGetHandler: () async -> BridgeSnapshotOutcome
    private let keepAwakeModeSetHandler: (KeepAwakeMode) async -> BridgeSnapshotOutcome
    private let historyClearHandler: () async -> BridgeSnapshotOutcome
    private let updatesCheckHandler: () async -> BridgeSnapshotOutcome
    private let updatesOpenHandler: () async -> BridgeVoidOutcome
    private let panelHideHandler: () async -> BridgeVoidOutcome
    private let appQuitHandler: () async -> BridgeVoidOutcome

    public init(
        snapshotGet: @escaping () async -> BridgeSnapshotOutcome,
        keepAwakeModeSet: @escaping (KeepAwakeMode) async -> BridgeSnapshotOutcome,
        historyClear: @escaping () async -> BridgeSnapshotOutcome,
        updatesCheck: @escaping () async -> BridgeSnapshotOutcome = { .failure(.unavailable) },
        updatesOpen: @escaping () async -> BridgeVoidOutcome = { .failure(.unavailable) },
        panelHide: @escaping () async -> BridgeVoidOutcome = { .failure(.unavailable) },
        appQuit: @escaping () async -> BridgeVoidOutcome = { .failure(.unavailable) }
    ) {
        self.snapshotGetHandler = snapshotGet
        self.keepAwakeModeSetHandler = keepAwakeModeSet
        self.historyClearHandler = historyClear
        self.updatesCheckHandler = updatesCheck
        self.updatesOpenHandler = updatesOpen
        self.panelHideHandler = panelHide
        self.appQuitHandler = appQuit
    }

    /// Wires `snapshot.get`/`keepAwakeMode.set`/`history.clear` to
    /// `coordinator` — the real Task 9 `AppSnapshotCoordinator` — reporting
    /// the coordinator's current `snapshot` after each call, matching the
    /// TS bridge's `BridgeMethodResultMap` (every one of these three
    /// methods resolves to a full, up-to-date `AppSnapshot`). Every other
    /// command is left at its `.unavailable` stub default.
    public static func forCoordinator(_ coordinator: AppSnapshotCoordinator) -> StandaloneBridgeCommandRouter {
        StandaloneBridgeCommandRouter(
            snapshotGet: {
                .success(coordinator.snapshot)
            },
            keepAwakeModeSet: { mode in
                do {
                    try await coordinator.setKeepAwakeMode(mode)
                    return .success(coordinator.snapshot)
                } catch {
                    return .failure(BridgeCommandError(code: .commandFailed, message: "Failed to update keep-awake mode"))
                }
            },
            historyClear: {
                do {
                    try await coordinator.clearHistory()
                    return .success(coordinator.snapshot)
                } catch {
                    return .failure(BridgeCommandError(code: .commandFailed, message: "Failed to clear history"))
                }
            }
        )
    }

    public func snapshotGet() async -> BridgeSnapshotOutcome { await snapshotGetHandler() }
    public func keepAwakeModeSet(_ mode: KeepAwakeMode) async -> BridgeSnapshotOutcome { await keepAwakeModeSetHandler(mode) }
    public func historyClear() async -> BridgeSnapshotOutcome { await historyClearHandler() }
    public func updatesCheck() async -> BridgeSnapshotOutcome { await updatesCheckHandler() }
    public func updatesOpen() async -> BridgeVoidOutcome { await updatesOpenHandler() }
    public func panelHide() async -> BridgeVoidOutcome { await panelHideHandler() }
    public func appQuit() async -> BridgeVoidOutcome { await appQuitHandler() }
}

/// Where `BridgeMessageHandler` delivers a routed request's response.
/// Exists so `BridgeMessageHandler` never depends on `WKWebView`/
/// `RendererEventSink` directly — production wiring supplies
/// `RendererEventSink.deliverResponse`, and tests inject a collecting fake.
@MainActor
public protocol BridgeResponding {
    func deliverResponse(_ response: BridgeResponse)
}

/// Bridges `WKScriptMessageHandler`'s untyped `WKScriptMessage.body` into
/// the strict, closed `BridgeRequest`/`BridgeCommandHandling` surface.
///
/// Responses are never returned via `WKScriptMessageHandlerWithReply`'s
/// completion value: the TS transport (`standalone-renderer-bridge.ts`)
/// correlates every response purely through `window.seerNative.receive`,
/// never through whatever `postMessage(...)` itself might resolve to — so
/// both responses and events are delivered uniformly through the same
/// `BridgeResponding`/`RendererEventSink` path, and this handler only ever
/// needs to conform to the plain (reply-less) `WKScriptMessageHandler`.
@MainActor
public final class BridgeMessageHandler: NSObject, WKScriptMessageHandler {
    /// The exact script message handler name the renderer's `postMessage`
    /// calls target (`window.webkit.messageHandlers.seerBridge`), and the
    /// name this handler must be registered under — in the `.page` content
    /// world only, never any other content world.
    public static let messageHandlerName = "seerBridge"

    private let router: any BridgeCommandHandling
    private let responder: any BridgeResponding

    /// In-flight command `Task`s, keyed by request id, so `cancelAll()` can
    /// cooperatively cancel every still-running command — e.g. when the
    /// owning web view is being torn down — without ever attempting a
    /// response delivery against a gone-away renderer. A new request that
    /// reuses an id still in flight supersedes (cancels) the older one
    /// rather than allowing two competing responses for the same id.
    private var inFlightTasks: [String: Task<Void, Never>] = [:]

    public init(router: any BridgeCommandHandling, responder: any BridgeResponding) {
        self.router = router
        self.responder = responder
    }

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        handle(body: message.body)
    }

    /// Entry point split out from `userContentController(_:didReceive:)` so
    /// tests can drive it with a synthetic body directly, without needing
    /// a real `WKUserContentController`/`WKScriptMessage` delivery.
    func handle(body: Any) {
        guard JSONSerialization.isValidJSONObject(body), let data = try? JSONSerialization.data(withJSONObject: body) else {
            // The body could not even be serialized back to JSON (e.g. it
            // is not a JSON object at all) — no request `id` can be
            // recovered from it, so there is nothing safe to correlate a
            // response to. This is intentionally dropped, matching the TS
            // transport's own behavior of simply timing out a request it
            // never receives any response for, rather than the native
            // host inventing a target id.
            return
        }
        route(data: data)
    }

    private func route(data: Data) {
        switch BridgeRequestDecoder.decode(data: data) {
        case .accepted(let request):
            dispatch(request)
        case .rejected(id: nil, error: _):
            // No trustworthy id could be recovered (the id itself may be
            // exactly what failed validation, or the message was too
            // malformed/oversized to extract one at all) — dropped rather
            // than guessed at, matching the TS transport's own behavior
            // of simply timing out a request it never receives any
            // response for.
            return
        case .rejected(id: .some(let id), error: let error):
            // The id passed validation before some *later* check failed
            // (wrong version, unknown method, or a known method's payload
            // shape) — respond immediately with a typed error so the
            // renderer's pending promise rejects now rather than waiting
            // out the full timeout.
            inFlightTasks[id]?.cancel()
            inFlightTasks.removeValue(forKey: id)
            responder.deliverResponse(.failure(id: id, error: error))
        }
    }

    private func dispatch(_ request: BridgeRequest) {
        inFlightTasks[request.id]?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.inFlightTasks.removeValue(forKey: request.id) }
            let response = await Self.execute(request, router: self.router)
            guard !Task.isCancelled else { return }
            self.responder.deliverResponse(response)
        }
        inFlightTasks[request.id] = task
    }

    private static func execute(_ request: BridgeRequest, router: any BridgeCommandHandling) async -> BridgeResponse {
        switch request.method {
        case .snapshotGet:
            return response(for: request.id, outcome: await router.snapshotGet())
        case .historyClear:
            return response(for: request.id, outcome: await router.historyClear())
        case .updatesCheck:
            return response(for: request.id, outcome: await router.updatesCheck())
        case .updatesOpen:
            return response(for: request.id, outcome: await router.updatesOpen())
        case .panelHide:
            return response(for: request.id, outcome: await router.panelHide())
        case .appQuit:
            return response(for: request.id, outcome: await router.appQuit())
        case .keepAwakeModeSet:
            guard case .keepAwakeMode(let mode) = request.payload else {
                return .failure(
                    id: request.id,
                    error: BridgeErrorPayload(code: .invalidPayload, message: "keepAwakeMode.set requires a mode payload")
                )
            }
            return response(for: request.id, outcome: await router.keepAwakeModeSet(mode))
        }
    }

    private static func response(for id: String, outcome: BridgeSnapshotOutcome) -> BridgeResponse {
        switch outcome {
        case .success(let snapshot):
            return .success(id: id, result: .snapshot(snapshot))
        case .failure(let error):
            return .failure(id: id, error: BridgeErrorPayload(code: error.code, message: error.message))
        }
    }

    private static func response(for id: String, outcome: BridgeVoidOutcome) -> BridgeResponse {
        switch outcome {
        case .success:
            return .success(id: id, result: .none)
        case .failure(let error):
            return .failure(id: id, error: BridgeErrorPayload(code: error.code, message: error.message))
        }
    }

    /// Cancels every in-flight command `Task`. Call this before the owning
    /// web view/window is torn down so no later `deliverResponse` call is
    /// ever attempted against a gone-away renderer.
    public func cancelAll() {
        for task in inFlightTasks.values {
            task.cancel()
        }
        inFlightTasks.removeAll()
    }
}
