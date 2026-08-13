import Foundation
import WebKit

/// Iteratively (never recursively) validates that a raw
/// `WKScriptMessage.body` is a JSON-compatible value before
/// `JSONSerialization` — which itself walks the object graph recursively
/// — or any `Mirror`-based reflection ever sees it. An explicit array-based
/// stack stands in for recursion, so no amount of nesting in `body` can
/// ever grow *this* call stack; `bridgeMaxBodyDepth` additionally bounds
/// the logical nesting depth accepted, `bridgeMaxBodyNodes` bounds the
/// total number of values walked (closing off "one huge flat array" as
/// well as "many small nested containers"), and `bridgeMaxBodyStringLength`
/// bounds any individual string leaf.
///
/// Accepts exactly the JSON-compatible universe: `String`-keyed
/// dictionaries, arrays, strings, booleans, numbers, and `NSNull`.
/// Anything else — a custom `NSObject` subclass, `Data`, `Date`, a
/// dictionary with a non-`String` key, ... — is rejected.
///
/// This validator only protects *this process's* handling of `body` once
/// it already exists as a native Foundation object graph. WebKit's own
/// bridging of a JS value into that graph happens before this code ever
/// runs, and — this is the residual, platform-owned risk a reviewer
/// flagged — deallocating a sufficiently deep chain of nested
/// `NSArray`/`NSDictionary` instances can itself recurse inside
/// Foundation's own `dealloc`, entirely outside this validator's control.
/// The bounds here stop this handler from *adding* a second recursive
/// walk (`JSONSerialization`) on top of that pre-existing risk; they
/// cannot retroactively undo work WebKit/Foundation already did
/// constructing (or will do tearing down) the object graph itself. Task
/// 12's isolated-content-world registration (`BridgeContentWorld`,
/// `BridgeMessageHandlerRegistration` below) is the mitigation for that
/// remaining surface: it keeps arbitrary page script from ever reaching
/// this handler in the first place.
enum BridgeMessageBodyValidator {
    private static let cfBooleanTypeID = CFBooleanGetTypeID()

    static func validate(_ root: Any) -> Bool {
        var stack: [(value: Any, depth: Int)] = [(root, 0)]
        var nodeCount = 1
        guard nodeCount <= bridgeMaxBodyNodes else { return false }

        while let (value, depth) = stack.popLast() {
            guard depth <= bridgeMaxBodyDepth else { return false }

            if value is NSNull {
                continue
            }
            // Checked *before* the `NSNumber` case below: a plain numeric
            // `NSNumber` can itself report success for `as? Bool` (the
            // classic CFBoolean/NSNumber bridging confusion), so only
            // `CFGetTypeID` reliably tells a real JSON boolean apart from
            // a JSON number.
            if CFGetTypeID(value as CFTypeRef) == cfBooleanTypeID {
                continue
            }
            if let string = value as? String {
                guard string.utf8.count <= bridgeMaxBodyStringLength else { return false }
                continue
            }
            if value is NSNumber {
                continue
            }
            if let array = value as? [Any] {
                for element in array {
                    nodeCount += 1
                    guard nodeCount <= bridgeMaxBodyNodes else { return false }
                    stack.append((element, depth + 1))
                }
                continue
            }
            if let dictionary = value as? [AnyHashable: Any] {
                for (key, element) in dictionary {
                    guard key is String else { return false }
                    nodeCount += 1
                    guard nodeCount <= bridgeMaxBodyNodes else { return false }
                    stack.append((element, depth + 1))
                }
                continue
            }
            // Anything else is outside the JSON-compatible universe.
            return false
        }
        return true
    }
}

/// The single `WKContentWorld` `BridgeMessageHandler` may ever be
/// registered under. Deliberately never `.page`: a script message handler
/// registered in `.page` is callable by *any* script executing in the
/// page's own JavaScript world — including a hostile script that somehow
/// ends up running there (an XSS in the renderer bundle, or any future
/// relaxation of `SeerNavigationPolicy`/`SeerSchemeResourceLoader`).
/// Registering instead in this dedicated, named isolated world means only
/// script explicitly executed *in that same world* (e.g. a trusted
/// `WKUserScript` Task 12 injects there) can ever reach
/// `window.webkit.messageHandlers.seerBridge.postMessage(...)` at all —
/// page-world script has no visibility of a handler registered under a
/// different content world.
@MainActor
public enum BridgeContentWorld {
    public static let bridge: WKContentWorld = .world(name: "com.seer.bridge")
}

/// The minimal script-message-handler-registration capability
/// `BridgeMessageHandlerRegistration` needs. `WKUserContentController`
/// conforms via the extension below; tests inject a fake so the exact
/// `(handler, contentWorld, name)` triple passed to `add` can be asserted
/// without needing a real `WKUserContentController`.
@MainActor
public protocol ScriptMessageHandlerRegistering: AnyObject {
    func add(_ scriptMessageHandler: WKScriptMessageHandler, contentWorld: WKContentWorld, name: String)
}

extension WKUserContentController: ScriptMessageHandlerRegistering {}

/// The one sanctioned way to wire a `BridgeMessageHandler` into a
/// `WKUserContentController`: always `BridgeMessageHandler
/// .messageHandlerName`, in `BridgeContentWorld.bridge`, never any other
/// name or content world. Task 12's real production wiring must call this
/// rather than `WKUserContentController.add(_:contentWorld:name:)`
/// directly, so a raw `.page`-world registration can never slip in
/// silently.
@MainActor
public enum BridgeMessageHandlerRegistration {
    public static func register(_ handler: BridgeMessageHandler, on controller: any ScriptMessageHandlerRegistering) {
        controller.add(handler, contentWorld: BridgeContentWorld.bridge, name: BridgeMessageHandler.messageHandlerName)
    }
}

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
    /// name this handler must be registered under. Registration itself
    /// must always go through `BridgeMessageHandlerRegistration.register`,
    /// which pins the content world to `BridgeContentWorld.bridge` — never
    /// `.page` — so this handler is only ever reachable by script running
    /// in that dedicated isolated world, not by arbitrary page script.
    public static let messageHandlerName = "seerBridge"

    private let router: any BridgeCommandHandling
    private let responder: any BridgeResponding

    /// One in-flight command `Task` entry, tagged with the monotonically
    /// unique `token` it was created with. `token` (not just presence in
    /// `inFlightTasks`) is what a completing task checks against before
    /// removing its own entry — see `completeInFlight(id:token:)` — so a
    /// superseded task's cleanup can never delete a *later* request's
    /// still-in-flight entry for the same id.
    private struct InFlightEntry {
        let token: UInt64
        let task: Task<Void, Never>
    }

    /// In-flight command task entries, keyed by request id, so
    /// `cancelAll()` can cooperatively cancel every still-running command
    /// — e.g. when the owning web view is being torn down — without ever
    /// attempting a response delivery against a gone-away renderer. A new
    /// request that reuses an id still in flight supersedes (cancels) the
    /// older one rather than allowing two competing responses for the
    /// same id.
    private var inFlightTasks: [String: InFlightEntry] = [:]

    /// Monotonically increasing source of `InFlightEntry.token` values.
    /// Wraps on overflow (`&+`) rather than trapping — by the time this
    /// would ever wrap, every token issued a full cycle ago is long gone
    /// from `inFlightTasks`, so identity is preserved in practice; a
    /// wrapped value is never treated as equal to a completely different,
    /// still-tracked token because `inFlightTasks` never holds more than a
    /// handful of entries at once.
    private var nextInFlightToken: UInt64 = 0

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
        // Run *before* `JSONSerialization` (and therefore before any
        // recursive walk of `body` at all): an iterative, depth/width/
        // string-length-bounded preflight. A body that fails this check is
        // dropped with no response, for the exact same reason as an
        // unserializable body below — no trustworthy id can be recovered
        // from it, and the TS transport's pending request (if any) simply
        // times out, exactly as if this message had never arrived.
        guard BridgeMessageBodyValidator.validate(body) else {
            return
        }
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
            // out the full timeout. This is itself the newest event for
            // `id` — nothing can supersede it further since a response is
            // delivered immediately with no new task created — so
            // unconditionally cancelling and removing whatever was
            // tracked for `id` is safe here (unlike a completing task's
            // own cleanup, which must check its token first).
            inFlightTasks[id]?.task.cancel()
            inFlightTasks.removeValue(forKey: id)
            responder.deliverResponse(.failure(id: id, error: error))
        }
    }

    private func dispatch(_ request: BridgeRequest) {
        // Cancel (but do not remove) whatever is currently tracked for
        // this id: the entry is about to be overwritten below regardless.
        inFlightTasks[request.id]?.task.cancel()
        nextInFlightToken = nextInFlightToken &+ 1
        let token = nextInFlightToken
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.completeInFlight(id: request.id, token: token) }
            let response = await Self.execute(request, router: self.router)
            guard !Task.isCancelled else { return }
            self.responder.deliverResponse(response)
        }
        inFlightTasks[request.id] = InFlightEntry(token: token, task: task)
    }

    /// Removes `inFlightTasks[id]` only if it is still the exact entry
    /// this dispatch created (`token` matches). A superseded task
    /// completing *after* a newer request already replaced its entry for
    /// the same id must never delete that newer entry — doing so is
    /// exactly the stale-task-map bug where a third same-id request could
    /// fail to cancel a second still-in-flight one, letting both respond.
    private func completeInFlight(id: String, token: UInt64) {
        guard inFlightTasks[id]?.token == token else { return }
        inFlightTasks.removeValue(forKey: id)
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
        for entry in inFlightTasks.values {
            entry.task.cancel()
        }
        inFlightTasks.removeAll()
    }
}
