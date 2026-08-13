import XCTest
import WebKit
@testable import Seer

/// A minimal, immediately-resolving `AppSnapshot` used across these tests
/// wherever only *some* valid snapshot value is needed, not a specific one.
private func makeSnapshot(appVersion: String = "1.0.0-test") -> AppSnapshot {
    .empty(version: appVersion)
}

/// A fully scriptable `BridgeCommandHandling` test double. Every method
/// records its call and returns whatever outcome the test pre-configured,
/// optionally suspending on `gate` (an `AsyncStreamContinuation`-backed
/// signal) so tests can exercise cancellation of a still-in-flight
/// command.
@MainActor
private final class FakeCommandRouter: BridgeCommandHandling {
    private(set) var snapshotGetCallCount = 0
    private(set) var keepAwakeModeSetCalls: [KeepAwakeMode] = []
    private(set) var historyClearCallCount = 0
    private(set) var updatesCheckCallCount = 0
    private(set) var updatesOpenCallCount = 0
    private(set) var panelHideCallCount = 0
    private(set) var appQuitCallCount = 0

    var snapshotGetOutcome: BridgeSnapshotOutcome = .success(makeSnapshot())
    var keepAwakeModeSetOutcome: BridgeSnapshotOutcome = .success(makeSnapshot())
    var historyClearOutcome: BridgeSnapshotOutcome = .success(makeSnapshot())
    var updatesCheckOutcome: BridgeSnapshotOutcome = .failure(.unavailable)
    var updatesOpenOutcome: BridgeVoidOutcome = .failure(.unavailable)
    var panelHideOutcome: BridgeVoidOutcome = .failure(.unavailable)
    var appQuitOutcome: BridgeVoidOutcome = .failure(.unavailable)

    /// When non-nil, `snapshotGet()` awaits this continuation before
    /// returning — lets a test hold a command "in flight" until it
    /// explicitly resumes it, to exercise `cancelAll()`/superseding
    /// dispatch behavior deterministically.
    var snapshotGetContinuation: CheckedContinuation<Void, Never>?
    var snapshotGetAwaitsSignal = false

    func snapshotGet() async -> BridgeSnapshotOutcome {
        snapshotGetCallCount += 1
        if snapshotGetAwaitsSignal {
            await withCheckedContinuation { continuation in
                snapshotGetContinuation = continuation
            }
        }
        return snapshotGetOutcome
    }

    func resumeSnapshotGet() {
        snapshotGetContinuation?.resume()
        snapshotGetContinuation = nil
    }

    func keepAwakeModeSet(_ mode: KeepAwakeMode) async -> BridgeSnapshotOutcome {
        keepAwakeModeSetCalls.append(mode)
        return keepAwakeModeSetOutcome
    }

    /// Same continuation-gating mechanism as `snapshotGet` above, but for
    /// `historyClear` — needed so a test can hold *two independent*
    /// commands in flight simultaneously (e.g. two same-id requests for
    /// different methods), which a single shared gate could not do.
    var historyClearContinuation: CheckedContinuation<Void, Never>?
    var historyClearAwaitsSignal = false

    func resumeHistoryClear() {
        historyClearContinuation?.resume()
        historyClearContinuation = nil
    }

    func historyClear() async -> BridgeSnapshotOutcome {
        historyClearCallCount += 1
        if historyClearAwaitsSignal {
            await withCheckedContinuation { continuation in
                historyClearContinuation = continuation
            }
        }
        return historyClearOutcome
    }

    func updatesCheck() async -> BridgeSnapshotOutcome {
        updatesCheckCallCount += 1
        return updatesCheckOutcome
    }

    func updatesOpen() async -> BridgeVoidOutcome {
        updatesOpenCallCount += 1
        return updatesOpenOutcome
    }

    func panelHide() async -> BridgeVoidOutcome {
        panelHideCallCount += 1
        return panelHideOutcome
    }

    func appQuit() async -> BridgeVoidOutcome {
        appQuitCallCount += 1
        return appQuitOutcome
    }
}

/// Collects every response `BridgeMessageHandler` delivers, in order —
/// exact values, so tests can assert both "exactly one response" and its
/// precise content.
@MainActor
private final class FakeResponder: BridgeResponding {
    private(set) var responses: [BridgeResponse] = []

    /// Resolved the next time `deliverResponse` is called, letting async
    /// tests `await` a response instead of polling.
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func deliverResponse(_ response: BridgeResponse) {
        responses.append(response)
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }

    /// Suspends until at least `count` responses have been delivered.
    func waitForResponses(count: Int) async {
        while responses.count < count {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }
    }
}

private func requestData(
    id: String = "550e8400-e29b-41d4-a716-446655440000",
    version: String = bridgeVersion,
    method: String = "snapshot.get",
    payload: [String: Any] = [:]
) -> Data {
    let object: [String: Any] = ["id": id, "version": version, "method": method, "payload": payload]
    return try! JSONSerialization.data(withJSONObject: object)
}

@MainActor
final class BridgeMessageHandlerTests: XCTestCase {
    // MARK: - BridgeRequestDecoder: size gate before decode

    func testOversizedBodyIsRejectedBeforeJSONDecodingIsAttempted() {
        // Deliberately not even valid JSON syntax: if the size gate ran
        // *after* attempting to decode, this would fail with `invalidJSON`
        // instead. Getting `messageTooLarge` instead proves the size check
        // runs first.
        let oversized = Data(repeating: 0x7B, count: bridgeMaxMessageBytes + 1) // a run of '{' bytes
        guard case .rejected(let id, let error) = BridgeRequestDecoder.decode(data: oversized) else {
            return XCTFail("expected a rejection")
        }
        XCTAssertNil(id)
        XCTAssertEqual(error.code, .messageTooLarge)
    }

    /// Payloads on this bridge are always small, closed shapes — there is
    /// no way to construct an actually-valid request near the 64KiB limit
    /// without violating the closed key-set rules tested elsewhere. This
    /// instead asserts the boundary check itself is inclusive (`<=`) using
    /// a normal, well-formed request far under the limit.
    func testWellFormedRequestFarUnderTheSizeLimitIsAccepted() {
        let data = requestData()
        XCTAssertLessThanOrEqual(data.count, bridgeMaxMessageBytes)
        guard case .accepted(let request) = BridgeRequestDecoder.decode(data: data) else {
            return XCTFail("expected acceptance")
        }
        XCTAssertEqual(request.method, .snapshotGet)
    }

    // MARK: - BridgeRequestDecoder: malformed JSON / shape

    func testMalformedJSONSyntaxIsRejectedAsInvalidJSON() {
        let data = Data("{not valid json".utf8)
        guard case .rejected(let id, let error) = BridgeRequestDecoder.decode(data: data) else {
            return XCTFail("expected a rejection")
        }
        XCTAssertNil(id)
        XCTAssertEqual(error.code, .invalidJSON)
    }

    func testNonObjectRootIsRejectedAsInvalidRequest() {
        for data in [Data("[]".utf8), Data("\"hello\"".utf8), Data("42".utf8), Data("null".utf8)] {
            guard case .rejected(let id, let error) = BridgeRequestDecoder.decode(data: data) else {
                return XCTFail("expected a rejection for \(data)")
            }
            XCTAssertNil(id)
            XCTAssertEqual(error.code, .invalidRequest)
        }
    }

    func testExtraTopLevelKeyIsRejectedAsInvalidRequest() {
        let object: [String: Any] = [
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "version": bridgeVersion,
            "method": "snapshot.get",
            "payload": [String: Any](),
            "debug": true,
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        guard case .rejected(let id, let error) = BridgeRequestDecoder.decode(data: data) else {
            return XCTFail("expected a rejection")
        }
        XCTAssertNil(id, "an extra top-level key means the id was never trusted enough to echo back")
        XCTAssertEqual(error.code, .invalidRequest)
    }

    func testMissingTopLevelKeyIsRejectedAsInvalidRequest() {
        let object: [String: Any] = [
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "version": bridgeVersion,
            "payload": [String: Any](),
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        guard case .rejected(let id, let error) = BridgeRequestDecoder.decode(data: data) else {
            return XCTFail("expected a rejection")
        }
        XCTAssertNil(id)
        XCTAssertEqual(error.code, .invalidRequest)
    }

    func testNonStringTopLevelFieldIsRejectedAsInvalidRequest() {
        let object: [String: Any] = [
            "id": 12345,
            "version": bridgeVersion,
            "method": "snapshot.get",
            "payload": [String: Any](),
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        guard case .rejected(let id, let error) = BridgeRequestDecoder.decode(data: data) else {
            return XCTFail("expected a rejection")
        }
        XCTAssertNil(id)
        XCTAssertEqual(error.code, .invalidRequest)
    }

    // MARK: - id validation

    func testEmptyIdIsRejectedWithNoEchoableId() {
        let data = requestData(id: "")
        guard case .rejected(let id, let error) = BridgeRequestDecoder.decode(data: data) else {
            return XCTFail("expected a rejection")
        }
        XCTAssertNil(id)
        XCTAssertEqual(error.code, .invalidRequest)
    }

    func testOverlongIdIsRejectedWithNoEchoableId() {
        let data = requestData(id: String(repeating: "a", count: bridgeMaxIdLength + 1))
        guard case .rejected(let id, let error) = BridgeRequestDecoder.decode(data: data) else {
            return XCTFail("expected a rejection")
        }
        XCTAssertNil(id)
        XCTAssertEqual(error.code, .invalidRequest)
    }

    func testIdWithDisallowedCharactersIsRejectedWithNoEchoableId() {
        let data = requestData(id: "not a uuid; drop table")
        guard case .rejected(let id, let error) = BridgeRequestDecoder.decode(data: data) else {
            return XCTFail("expected a rejection")
        }
        XCTAssertNil(id)
        XCTAssertEqual(error.code, .invalidRequest)
    }

    // MARK: - version validation

    func testWrongVersionIsRejectedAndEchoesTheValidId() {
        let data = requestData(version: "seer.bridge.v2")
        guard case .rejected(let id, let error) = BridgeRequestDecoder.decode(data: data) else {
            return XCTFail("expected a rejection")
        }
        XCTAssertEqual(id, "550e8400-e29b-41d4-a716-446655440000")
        XCTAssertEqual(error.code, .invalidVersion)
    }

    // MARK: - unknown method (including a dangerous-looking one)

    func testUnknownMethodIsRejectedAndEchoesTheValidId() {
        let data = requestData(method: "shell.execute")
        guard case .rejected(let id, let error) = BridgeRequestDecoder.decode(data: data) else {
            return XCTFail("expected a rejection")
        }
        XCTAssertEqual(id, "550e8400-e29b-41d4-a716-446655440000")
        XCTAssertEqual(error.code, .unknownMethod)
    }

    // MARK: - payload exactness: empty-payload methods

    func testEveryParameterlessMethodAcceptsOnlyAnExactlyEmptyPayload() {
        for method in ["snapshot.get", "history.clear", "updates.check", "updates.open", "panel.hide", "app.quit"] {
            let data = requestData(method: method, payload: [:])
            guard case .accepted(let request) = BridgeRequestDecoder.decode(data: data) else {
                return XCTFail("expected acceptance for \(method)")
            }
            XCTAssertEqual(request.payload, .empty)
        }
    }

    func testExtraKeyInEmptyPayloadIsRejectedAsInvalidPayloadAndEchoesTheId() {
        let data = requestData(method: "history.clear", payload: ["extra": "value"])
        guard case .rejected(let id, let error) = BridgeRequestDecoder.decode(data: data) else {
            return XCTFail("expected a rejection")
        }
        XCTAssertEqual(id, "550e8400-e29b-41d4-a716-446655440000")
        XCTAssertEqual(error.code, .invalidPayload)
    }

    func testNonObjectPayloadIsRejectedAsInvalidPayload() {
        for payloadJSON in ["[]", "null", "\"x\"", "1"] {
            let object = "{\"id\":\"550e8400-e29b-41d4-a716-446655440000\",\"version\":\"\(bridgeVersion)\",\"method\":\"snapshot.get\",\"payload\":\(payloadJSON)}"
            let data = Data(object.utf8)
            guard case .rejected(_, let error) = decodeAsRejection(data) else {
                return XCTFail("expected a rejection for payload \(payloadJSON)")
            }
            XCTAssertEqual(error.code, .invalidPayload, "payload \(payloadJSON) should be rejected as invalid_payload")
        }
    }

    private func decodeAsRejection(_ data: Data) -> BridgeDecodeOutcome {
        BridgeRequestDecoder.decode(data: data)
    }

    // MARK: - payload exactness: keepAwakeMode.set

    func testKeepAwakeModeSetAcceptsExactlySystemOrDisplay() {
        for (raw, expected) in [("system", KeepAwakeMode.system), ("display", KeepAwakeMode.display)] {
            let data = requestData(method: "keepAwakeMode.set", payload: ["mode": raw])
            guard case .accepted(let request) = BridgeRequestDecoder.decode(data: data) else {
                return XCTFail("expected acceptance for mode \(raw)")
            }
            XCTAssertEqual(request.payload, .keepAwakeMode(expected))
        }
    }

    func testKeepAwakeModeSetMissingModeKeyIsRejectedAsInvalidPayload() {
        let data = requestData(method: "keepAwakeMode.set", payload: [:])
        guard case .rejected(let id, let error) = BridgeRequestDecoder.decode(data: data) else {
            return XCTFail("expected a rejection")
        }
        XCTAssertEqual(id, "550e8400-e29b-41d4-a716-446655440000")
        XCTAssertEqual(error.code, .invalidPayload)
    }

    func testKeepAwakeModeSetExtraKeyIsRejectedAsInvalidPayload() {
        let data = requestData(method: "keepAwakeMode.set", payload: ["mode": "system", "extra": 1])
        guard case .rejected(_, let error) = decodeAsRejection(data) else {
            return XCTFail("expected a rejection")
        }
        XCTAssertEqual(error.code, .invalidPayload)
    }

    func testKeepAwakeModeSetUnrecognizedModeStringIsRejectedAsInvalidPayload() {
        let data = requestData(method: "keepAwakeMode.set", payload: ["mode": "not-a-mode"])
        guard case .rejected(_, let error) = decodeAsRejection(data) else {
            return XCTFail("expected a rejection")
        }
        XCTAssertEqual(error.code, .invalidPayload)
    }

    /// The classic Foundation NSNumber pitfall: a JSON boolean must never
    /// be silently accepted where a string (`mode`) is expected, nor vice
    /// versa. `JSONDecoder`'s `decode(String.self, forKey:)` genuinely
    /// requires a JSON string token — a JSON `true`/`false`/number token
    /// throws a type mismatch rather than being coerced.
    func testKeepAwakeModeBooleanValueIsRejectedNotCoerced() {
        let object: [String: Any] = [
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "version": bridgeVersion,
            "method": "keepAwakeMode.set",
            "payload": ["mode": true],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        guard case .rejected(_, let error) = decodeAsRejection(data) else {
            return XCTFail("expected a rejection")
        }
        XCTAssertEqual(error.code, .invalidPayload)
    }

    func testKeepAwakeModeNumericValueIsRejectedNotCoerced() {
        let data = requestData(method: "keepAwakeMode.set", payload: ["mode": 1])
        guard case .rejected(_, let error) = decodeAsRejection(data) else {
            return XCTFail("expected a rejection")
        }
        XCTAssertEqual(error.code, .invalidPayload)
    }

    func testKeepAwakeModeNullValueIsRejectedNotCoerced() {
        let object = "{\"id\":\"550e8400-e29b-41d4-a716-446655440000\",\"version\":\"\(bridgeVersion)\",\"method\":\"keepAwakeMode.set\",\"payload\":{\"mode\":null}}"
        guard case .rejected(_, let error) = decodeAsRejection(Data(object.utf8)) else {
            return XCTFail("expected a rejection")
        }
        XCTAssertEqual(error.code, .invalidPayload)
    }

    func testKeepAwakeModeArrayValueIsRejectedNotCoerced() {
        let data = requestData(method: "keepAwakeMode.set", payload: ["mode": ["system"]])
        guard case .rejected(_, let error) = decodeAsRejection(data) else {
            return XCTFail("expected a rejection")
        }
        XCTAssertEqual(error.code, .invalidPayload)
    }

    // MARK: - BridgeMessageHandler: routing + exactly-one-response

    func testValidSnapshotGetRequestIsRoutedAndProducesASuccessResponse() async {
        let router = FakeCommandRouter()
        let snapshot = makeSnapshot(appVersion: "9.9.9")
        router.snapshotGetOutcome = .success(snapshot)
        let responder = FakeResponder()
        let handler = BridgeMessageHandler(router: router, responder: responder)

        handler.handle(body: ["id": "550e8400-e29b-41d4-a716-446655440000", "version": bridgeVersion, "method": "snapshot.get", "payload": [String: Any]()])
        await responder.waitForResponses(count: 1)

        XCTAssertEqual(router.snapshotGetCallCount, 1)
        XCTAssertEqual(responder.responses.count, 1)
        XCTAssertEqual(responder.responses[0], .success(id: "550e8400-e29b-41d4-a716-446655440000", result: .snapshot(snapshot)))
    }

    func testKeepAwakeModeSetRequestPassesTheDecodedMode() async {
        let router = FakeCommandRouter()
        let responder = FakeResponder()
        let handler = BridgeMessageHandler(router: router, responder: responder)

        handler.handle(body: [
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "version": bridgeVersion,
            "method": "keepAwakeMode.set",
            "payload": ["mode": "display"],
        ])
        await responder.waitForResponses(count: 1)

        XCTAssertEqual(router.keepAwakeModeSetCalls, [.display])
    }

    func testHistoryClearRequestRoutesToTheRouter() async {
        let router = FakeCommandRouter()
        let responder = FakeResponder()
        let handler = BridgeMessageHandler(router: router, responder: responder)

        handler.handle(body: ["id": "550e8400-e29b-41d4-a716-446655440000", "version": bridgeVersion, "method": "history.clear", "payload": [String: Any]()])
        await responder.waitForResponses(count: 1)

        XCTAssertEqual(router.historyClearCallCount, 1)
    }

    func testVoidMethodsResolveWithResultNone() async {
        let router = FakeCommandRouter()
        router.updatesOpenOutcome = .success(())
        let responder = FakeResponder()
        let handler = BridgeMessageHandler(router: router, responder: responder)

        handler.handle(body: ["id": "550e8400-e29b-41d4-a716-446655440000", "version": bridgeVersion, "method": "updates.open", "payload": [String: Any]()])
        await responder.waitForResponses(count: 1)

        XCTAssertEqual(responder.responses[0], .success(id: "550e8400-e29b-41d4-a716-446655440000", result: .none))
    }

    func testNotYetImplementedCommandsReportCommandUnavailableByDefault() async {
        let router = FakeCommandRouter()
        let responder = FakeResponder()
        let handler = BridgeMessageHandler(router: router, responder: responder)

        for method in ["updates.check", "panel.hide", "app.quit"] {
            let id = UUID().uuidString
            handler.handle(body: ["id": id, "version": bridgeVersion, "method": method, "payload": [String: Any]()])
        }
        await responder.waitForResponses(count: 3)

        XCTAssertEqual(responder.responses.count, 3)
        for response in responder.responses {
            guard case .failure(_, let error) = response else {
                return XCTFail("expected a failure response for \(response)")
            }
            XCTAssertEqual(error.code, .commandUnavailable)
        }
    }

    func testUnknownMethodShellExecuteNeverReachesTheRouterAndRespondsUnknownMethod() async {
        let router = FakeCommandRouter()
        let responder = FakeResponder()
        let handler = BridgeMessageHandler(router: router, responder: responder)

        handler.handle(body: ["id": "550e8400-e29b-41d4-a716-446655440000", "version": bridgeVersion, "method": "shell.execute", "payload": [String: Any]()])
        await responder.waitForResponses(count: 1)

        XCTAssertEqual(router.snapshotGetCallCount, 0)
        XCTAssertEqual(router.historyClearCallCount, 0)
        guard case .failure(let id, let error) = responder.responses[0] else {
            return XCTFail("expected a failure response")
        }
        XCTAssertEqual(id, "550e8400-e29b-41d4-a716-446655440000")
        XCTAssertEqual(error.code, .unknownMethod)
    }

    func testMalformedMessageWithNoTrustworthyIdIsDroppedWithoutAnyResponse() async {
        let router = FakeCommandRouter()
        let responder = FakeResponder()
        let handler = BridgeMessageHandler(router: router, responder: responder)

        handler.handle(body: ["not": "a bridge request"])
        // Give any (incorrectly) scheduled work a turn to run.
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(responder.responses.count, 0)
        XCTAssertEqual(router.snapshotGetCallCount, 0)
    }

    func testUnserializableBodyIsDroppedWithoutAnyResponse() async {
        let router = FakeCommandRouter()
        let responder = FakeResponder()
        let handler = BridgeMessageHandler(router: router, responder: responder)

        // `NSObject()` cannot be represented as a JSON object at all.
        handler.handle(body: NSObject())
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(responder.responses.count, 0)
    }

    // MARK: - cancellation / exactly-one-response under supersession

    func testCancelAllPreventsAResponseForAStillInFlightCommand() async {
        let router = FakeCommandRouter()
        router.snapshotGetAwaitsSignal = true
        let responder = FakeResponder()
        let handler = BridgeMessageHandler(router: router, responder: responder)

        handler.handle(body: ["id": "550e8400-e29b-41d4-a716-446655440000", "version": bridgeVersion, "method": "snapshot.get", "payload": [String: Any]()])

        // Let the dispatched Task actually start and reach the point
        // where it is suspended awaiting the router's continuation.
        for _ in 0..<50 where router.snapshotGetContinuation == nil {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(router.snapshotGetCallCount, 1)

        handler.cancelAll()
        router.resumeSnapshotGet()

        // Give the (now-cancelled) task a chance to run to completion if
        // it incorrectly ignored cancellation.
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(responder.responses.count, 0, "a cancelled in-flight command must never still deliver a response")
    }

    func testASecondRequestWithTheSameIdSupersedesTheFirstRatherThanDoubleResponding() async {
        let router = FakeCommandRouter()
        router.snapshotGetAwaitsSignal = true
        let responder = FakeResponder()
        let handler = BridgeMessageHandler(router: router, responder: responder)
        let sharedID = "550e8400-e29b-41d4-a716-446655440000"

        handler.handle(body: ["id": sharedID, "version": bridgeVersion, "method": "snapshot.get", "payload": [String: Any]()])
        for _ in 0..<50 where router.snapshotGetContinuation == nil {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }

        // A second request reusing the same id, this time for a different
        // (immediately-resolving) method, should supersede the first.
        router.historyClearOutcome = .success(makeSnapshot(appVersion: "second"))
        handler.handle(body: ["id": sharedID, "version": bridgeVersion, "method": "history.clear", "payload": [String: Any]()])
        await responder.waitForResponses(count: 1)

        // Now let the first (superseded, cancelled) command's continuation
        // resume — it must not add a second response for the same id.
        router.resumeSnapshotGet()
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(responder.responses.count, 1, "only the superseding request should ever produce a response")
        XCTAssertEqual(responder.responses[0], .success(id: sharedID, result: .snapshot(makeSnapshot(appVersion: "second"))))
    }

    // MARK: - Wiring against the real Task 9 AppSnapshotCoordinator

    func testStandaloneBridgeCommandRouterForCoordinatorWiresSnapshotGetKeepAwakeModeSetAndHistoryClear() async {
        let settingsFileSystem = InMemorySettingsFileSystem()
        let historyFileSystem = InMemorySettingsFileSystem()
        let clock = MutableClock(now: 1_700_000_000_000)
        let settingsStore = SettingsStore(
            store: AtomicJSONStore<SettingsDocument>(
                fileURL: URL(fileURLWithPath: "/Bridge-Coordinator-Test/settings.json"),
                fileSystem: settingsFileSystem,
                clock: clock
            )
        )
        let historyStore = HistoryStore(
            store: AtomicJSONStore<HistoryDocument>(
                fileURL: URL(fileURLWithPath: "/Bridge-Coordinator-Test/history.json"),
                fileSystem: historyFileSystem,
                clock: clock
            ),
            clock: clock,
            scheduler: ManualHistoryScheduler(),
            idGenerator: SequentialHistorySessionIDGenerator()
        )
        let power = PowerAssertionService(backend: AppSnapshotCoordinatorTests.CoordinatorFakePowerBackend())
        final class CollectingSink: AppSnapshotRendererSink {
            func emit(_ snapshot: AppSnapshot) {}
        }
        let coordinator = await AppSnapshotCoordinator.makeAtStartup(
            settingsStore: settingsStore,
            historyStore: historyStore,
            power: power,
            renderer: CollectingSink(),
            clock: clock,
            appVersion: "1.2.3"
        )

        let router = StandaloneBridgeCommandRouter.forCoordinator(coordinator)

        guard case .success(let initialSnapshot) = await router.snapshotGet() else {
            return XCTFail("expected snapshot.get to succeed")
        }
        XCTAssertEqual(initialSnapshot.appVersion, "1.2.3")

        guard case .success(let afterMode) = await router.keepAwakeModeSet(.display) else {
            return XCTFail("expected keepAwakeMode.set to succeed")
        }
        XCTAssertEqual(afterMode.monitor.keepAwakeMode, .display)

        guard case .success(let afterClear) = await router.historyClear() else {
            return XCTFail("expected history.clear to succeed")
        }
        XCTAssertEqual(afterClear.history.sessionCount, 0)

        // Not-yet-implemented commands remain stubbed as unavailable even
        // when the router is wired to a real coordinator.
        guard case .failure(let updatesError) = await router.updatesCheck() else {
            return XCTFail("expected updates.check to be unavailable")
        }
        XCTAssertEqual(updatesError.code, .commandUnavailable)
        guard case .failure(let quitError) = await router.appQuit() else {
            return XCTFail("expected app.quit to be unavailable")
        }
        XCTAssertEqual(quitError.code, .commandUnavailable)
    }

    // MARK: - BridgeMessageBodyValidator: non-recursive preflight before JSONSerialization

    /// Builds `Any` where `depth` measures how many levels below the root
    /// the leaf string sits (a `depth` of 0 is just `"leaf"` itself, a
    /// `depth` of 1 is `["leaf"]`, etc.) — matching the exact semantics
    /// `BridgeMessageBodyValidator.validate` bounds via `bridgeMaxBodyDepth`.
    private func nestedArray(depth: Int) -> Any {
        var value: Any = "leaf"
        for _ in 0..<depth {
            value = [value]
        }
        return value
    }

    func testValidatorAcceptsExactlyMaxDepth() {
        XCTAssertTrue(BridgeMessageBodyValidator.validate(nestedArray(depth: bridgeMaxBodyDepth)))
    }

    func testValidatorRejectsOneDeeperThanMaxDepth() {
        XCTAssertFalse(BridgeMessageBodyValidator.validate(nestedArray(depth: bridgeMaxBodyDepth + 1)))
    }

    /// A moderately deep (well past `bridgeMaxBodyDepth`, but nowhere near
    /// large enough to risk a crash tearing this test's own fixture down)
    /// nested native array — safe to construct and deallocate in an
    /// `XCTest`'s own process. Exercises the validator's non-recursive
    /// walk directly, independent of `handle(body:)`.
    func testValidatorRejectsAModeratelyDeepNestedBodyWithoutCrashing() {
        let deeplyNested = nestedArray(depth: 200)
        XCTAssertFalse(BridgeMessageBodyValidator.validate(deeplyNested))
    }

    func testValidatorRejectsAWideNodeCountOverTheLimit() {
        let wideArray = Array(repeating: "x", count: bridgeMaxBodyNodes + 10)
        XCTAssertFalse(BridgeMessageBodyValidator.validate(wideArray))
    }

    func testValidatorAcceptsANodeCountAtTheLimit() {
        // The root array itself counts as one node, so its elements may
        // total at most `bridgeMaxBodyNodes - 1` while still fitting
        // within `bridgeMaxBodyNodes` overall.
        let wideArray = Array(repeating: "x", count: bridgeMaxBodyNodes - 1)
        XCTAssertTrue(BridgeMessageBodyValidator.validate(wideArray))
    }

    func testValidatorRejectsANonStringDictionaryKey() {
        let dictionaryWithIntKey = NSDictionary(dictionary: [1: "value"])
        XCTAssertFalse(BridgeMessageBodyValidator.validate(dictionaryWithIntKey))
    }

    func testValidatorRejectsAMixOfStringAndNonStringDictionaryKeys() {
        let mixedKeys = NSDictionary(dictionary: ["ok": "value", 2: "other"])
        XCTAssertFalse(BridgeMessageBodyValidator.validate(mixedKeys))
    }

    func testValidatorRejectsAStringLongerThanTheMaximum() {
        let tooLong = String(repeating: "a", count: bridgeMaxBodyStringLength + 1)
        XCTAssertFalse(BridgeMessageBodyValidator.validate(["value": tooLong]))
    }

    func testValidatorAcceptsAStringExactlyAtTheMaximum() {
        let atLimit = String(repeating: "a", count: bridgeMaxBodyStringLength)
        XCTAssertTrue(BridgeMessageBodyValidator.validate(["value": atLimit]))
    }

    func testValidatorRejectsANonJSONCompatibleLeafValue() {
        XCTAssertFalse(BridgeMessageBodyValidator.validate(NSObject()))
        XCTAssertFalse(BridgeMessageBodyValidator.validate(Date()))
        XCTAssertFalse(BridgeMessageBodyValidator.validate(Data([0x01, 0x02])))
    }

    /// The classic CFBoolean/`NSNumber` confusion: a real JSON boolean and
    /// a real JSON number must both still validate correctly (neither
    /// rejected nor conflated with the other) once boolean detection uses
    /// `CFGetTypeID` rather than a bare `as? Bool` cast.
    func testValidatorAcceptsBothBooleansAndNumbersDistinctly() {
        XCTAssertTrue(BridgeMessageBodyValidator.validate(["flag": true, "count": 42, "ratio": 1.5]))
    }

    func testValidatorAcceptsNSNull() {
        XCTAssertTrue(BridgeMessageBodyValidator.validate(NSNull()))
    }

    func testValidatorAcceptsAnOrdinaryWellFormedRequestBody() {
        let body: [String: Any] = [
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "version": bridgeVersion,
            "method": "keepAwakeMode.set",
            "payload": ["mode": "display"],
        ]
        XCTAssertTrue(BridgeMessageBodyValidator.validate(body))
    }

    // MARK: - handle(body:): the validator gate runs before JSONSerialization

    /// Proves the validator gate, not `JSONSerialization`/`BridgeRequestDecoder`,
    /// is what rejects an over-deep body: the router is never invoked and
    /// no response is ever delivered, exactly matching the "unserializable
    /// body" drop behavior below it — an over-deep body never even
    /// reaches the `JSONSerialization.isValidJSONObject` call, let alone
    /// the decoder.
    func testHandleDropsAnOverDeepBodyBeforeReachingTheRouterOrResponder() async {
        let router = FakeCommandRouter()
        let responder = FakeResponder()
        let handler = BridgeMessageHandler(router: router, responder: responder)

        handler.handle(body: nestedArray(depth: 200))
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(responder.responses.count, 0)
        XCTAssertEqual(router.snapshotGetCallCount, 0)
        XCTAssertEqual(router.historyClearCallCount, 0)
    }

    func testHandleDropsAWideOverNodeCountBodyBeforeReachingTheRouterOrResponder() async {
        let router = FakeCommandRouter()
        let responder = FakeResponder()
        let handler = BridgeMessageHandler(router: router, responder: responder)

        handler.handle(body: Array(repeating: "x", count: bridgeMaxBodyNodes + 10))
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(responder.responses.count, 0)
        XCTAssertEqual(router.snapshotGetCallCount, 0)
    }

    // MARK: - BridgeContentWorld / BridgeMessageHandlerRegistration

    private final class FakeScriptMessageHandlerRegistering: ScriptMessageHandlerRegistering {
        private(set) var addedHandler: WKScriptMessageHandler?
        private(set) var addedContentWorld: WKContentWorld?
        private(set) var addedName: String?
        private(set) var addCallCount = 0
        private(set) var addedUserScripts: [WKUserScript] = []
        /// Records the interleaving of `add`/`addUserScript` calls, in
        /// order, so tests can assert the exact deterministic ordering
        /// `BridgeMessageHandlerRegistration.register` documents.
        private(set) var callOrder: [String] = []

        func add(_ scriptMessageHandler: WKScriptMessageHandler, contentWorld: WKContentWorld, name: String) {
            addCallCount += 1
            addedHandler = scriptMessageHandler
            addedContentWorld = contentWorld
            addedName = name
            callOrder.append("add")
        }

        func addUserScript(_ userScript: WKUserScript) {
            addedUserScripts.append(userScript)
            callOrder.append("addUserScript")
        }
    }

    func testBridgeContentWorldIsNeverThePageWorld() {
        XCTAssertFalse(
            BridgeContentWorld.bridge === WKContentWorld.page,
            "the bridge handler must never be registered in the page content world"
        )
    }

    func testRegistrationHelperWiresTheHandlerUnderTheBridgeContentWorldAndExactName() {
        let router = FakeCommandRouter()
        let responder = FakeResponder()
        let handler = BridgeMessageHandler(router: router, responder: responder)
        let registering = FakeScriptMessageHandlerRegistering()

        BridgeMessageHandlerRegistration.register(handler, on: registering)

        XCTAssertEqual(registering.addCallCount, 1)
        XCTAssertTrue(registering.addedHandler === handler)
        XCTAssertEqual(registering.addedName, BridgeMessageHandler.messageHandlerName)
        XCTAssertTrue(registering.addedContentWorld === BridgeContentWorld.bridge)
        XCTAssertFalse(registering.addedContentWorld === WKContentWorld.page, "must never register in .page")
    }

    func testRegistrationHelperAlsoInjectsExactlyOneRelayUserScriptInTheBridgeContentWorld() {
        let router = FakeCommandRouter()
        let responder = FakeResponder()
        let handler = BridgeMessageHandler(router: router, responder: responder)
        let registering = FakeScriptMessageHandlerRegistering()

        BridgeMessageHandlerRegistration.register(handler, on: registering)

        XCTAssertEqual(registering.addedUserScripts.count, 1)
        let script = registering.addedUserScripts[0]
        // `WKUserScript` does not expose a readable `contentWorld`
        // property (it is init-only), so the exact content world it was
        // constructed with cannot be introspected directly here — that is
        // instead proven behaviorally by the real `WKWebView` integration
        // tests below (`testRealWKWebViewPageWorldScript...`), which show
        // the relay script actually runs in `BridgeContentWorld.bridge`
        // (able to reach the handler) and page-world script cannot see
        // the handler directly.
        XCTAssertEqual(script.injectionTime, .atDocumentStart)
        XCTAssertTrue(script.isForMainFrameOnly)
        XCTAssertEqual(script.source, BridgeRelayUserScript.source)
    }

    func testRegistrationHelperAddsTheRelayUserScriptBeforeTheMessageHandlerInDeterministicOrder() {
        let router = FakeCommandRouter()
        let responder = FakeResponder()
        let handler = BridgeMessageHandler(router: router, responder: responder)
        let registering = FakeScriptMessageHandlerRegistering()

        BridgeMessageHandlerRegistration.register(handler, on: registering)

        XCTAssertEqual(registering.callOrder, ["addUserScript", "add"])
    }

    func testBridgeRelayUserScriptTokensAreTheExactFixedContractValues() {
        // These exact literal values are the contract with the TS side
        // (`DOM_RELAY_ATTRIBUTE`/`DOM_RELAY_EVENT_NAME` in
        // `renderer/bridge/dom-relay-port.ts`) — Swift and TypeScript
        // cannot share source, so this pins the Swift side of that
        // contract; `dom-relay-port.test.ts` pins the TS side.
        XCTAssertEqual(BridgeRelayUserScript.attributeName, "data-seer-bridge-payload")
        XCTAssertEqual(BridgeRelayUserScript.eventName, "seer-bridge-relay")
    }

    func testBridgeRelayUserScriptSourceReferencesTheFixedTokensAndTheHandlerNameOnly() {
        let source = BridgeRelayUserScript.source
        XCTAssertTrue(source.contains(BridgeRelayUserScript.attributeName))
        XCTAssertTrue(source.contains(BridgeRelayUserScript.eventName))
        XCTAssertTrue(source.contains("window.webkit.messageHandlers.\(BridgeMessageHandler.messageHandlerName).postMessage"))
        // No eval/interpolation of arbitrary content: the value read from
        // the attribute is passed straight to `postMessage`, never through
        // `eval`, `JSON.parse`, `Function(...)`, or string concatenation
        // that could execute it.
        XCTAssertFalse(source.contains("eval("))
        XCTAssertFalse(source.contains("Function("))
        XCTAssertFalse(source.contains("JSON.parse"))
    }

    // MARK: - production string-only entry point (handleScriptMessageBody)

    func testHandleScriptMessageBodyRoutesAValidJSONStringAllTheWayToASuccessResponse() async {
        let router = FakeCommandRouter()
        router.snapshotGetOutcome = .success(makeSnapshot())
        let responder = FakeResponder()
        let handler = BridgeMessageHandler(router: router, responder: responder)
        let json = String(data: requestData(), encoding: .utf8)!

        handler.handleScriptMessageBody(json)
        await responder.waitForResponses(count: 1)

        XCTAssertEqual(router.snapshotGetCallCount, 1)
        XCTAssertEqual(responder.responses.count, 1)
        guard case .success(let id, _) = responder.responses[0] else {
            return XCTFail("expected a success response")
        }
        XCTAssertEqual(id, "550e8400-e29b-41d4-a716-446655440000")
    }

    func testHandleScriptMessageBodyDropsANonStringObjectBodyWithoutJSONSerializationOrRouting() async {
        let router = FakeCommandRouter()
        let responder = FakeResponder()
        let handler = BridgeMessageHandler(router: router, responder: responder)

        // An arbitrary object graph — exactly the shape `handle(body:)`
        // (the arbitrary-native-body test path) accepts, but which the
        // production entry point must reject outright without ever
        // reaching `BridgeMessageBodyValidator`/`JSONSerialization`/the
        // router.
        handler.handleScriptMessageBody(["id": "550e8400-e29b-41d4-a716-446655440000", "version": bridgeVersion, "method": "snapshot.get", "payload": [String: Any]()])
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(responder.responses.count, 0)
        XCTAssertEqual(router.snapshotGetCallCount, 0)
    }

    func testHandleScriptMessageBodyDropsANonJSONNativeTypeBodySuchAsNSObject() async {
        let router = FakeCommandRouter()
        let responder = FakeResponder()
        let handler = BridgeMessageHandler(router: router, responder: responder)

        handler.handleScriptMessageBody(NSObject())
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(responder.responses.count, 0)
        XCTAssertEqual(router.snapshotGetCallCount, 0)
    }

    func testHandleScriptMessageBodyDropsAnOversizedStringWithoutRoutingOrResponding() async {
        let router = FakeCommandRouter()
        let responder = FakeResponder()
        let handler = BridgeMessageHandler(router: router, responder: responder)
        let oversized = String(repeating: "x", count: bridgeMaxMessageBytes + 1)

        handler.handleScriptMessageBody(oversized)
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(responder.responses.count, 0)
        XCTAssertEqual(router.snapshotGetCallCount, 0)
    }

    func testHandleScriptMessageBodyAcceptsAWellFormedRequestStringFarUnderTheSizeLimit() async {
        let router = FakeCommandRouter()
        router.snapshotGetOutcome = .success(makeSnapshot())
        let responder = FakeResponder()
        let handler = BridgeMessageHandler(router: router, responder: responder)
        let json = String(data: requestData(), encoding: .utf8)!
        XCTAssertLessThanOrEqual(json.utf8.count, bridgeMaxMessageBytes)

        handler.handleScriptMessageBody(json)
        await responder.waitForResponses(count: 1)

        XCTAssertEqual(responder.responses.count, 1)
        XCTAssertEqual(router.snapshotGetCallCount, 1)
    }

    // MARK: - stale task-map: three same-id requests must never double-respond



    /// Reproduces the exact race the token-based `inFlightTasks` entries
    /// guard against: request A is dispatched and left suspended
    /// in-flight; request B (same id, a different method) supersedes it
    /// and is also left suspended in-flight; A is *then* resumed and
    /// allowed to run to completion first — its cleanup must not delete
    /// B's now-current entry. Only then is request C (same id, a third
    /// method) dispatched, which must correctly find and cancel B. Only
    /// C's response may ever be delivered.
    func testThreeSameIdRequestsResumingTheFirstBeforeTheSecondFinishesOnlyTheThirdResponds() async {
        let router = FakeCommandRouter()
        router.snapshotGetAwaitsSignal = true
        router.historyClearAwaitsSignal = true
        let responder = FakeResponder()
        let handler = BridgeMessageHandler(router: router, responder: responder)
        let sharedID = "550e8400-e29b-41d4-a716-446655440000"

        // A: snapshot.get, held in flight.
        handler.handle(body: ["id": sharedID, "version": bridgeVersion, "method": "snapshot.get", "payload": [String: Any]()])
        for _ in 0..<50 where router.snapshotGetContinuation == nil {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(router.snapshotGetCallCount, 1)

        // B: history.clear, same id — supersedes A, also held in flight.
        handler.handle(body: ["id": sharedID, "version": bridgeVersion, "method": "history.clear", "payload": [String: Any]()])
        for _ in 0..<50 where router.historyClearContinuation == nil {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(router.historyClearCallCount, 1)

        // Resume A *before* B finishes. A's (superseded) cleanup must not
        // remove B's entry from the in-flight map.
        router.resumeSnapshotGet()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(responder.responses.count, 0, "A was superseded and cancelled — it must never deliver a response")

        // C: keepAwakeMode.set, same id, immediately resolving — must
        // correctly find and cancel B (proving B's entry survived A's
        // cleanup above), then take over the id.
        handler.handle(body: [
            "id": sharedID, "version": bridgeVersion, "method": "keepAwakeMode.set", "payload": ["mode": "display"],
        ])
        await responder.waitForResponses(count: 1)

        // Now let B's (superseded, cancelled) continuation resume — it
        // must not add a second response.
        router.resumeHistoryClear()
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(responder.responses.count, 1, "only C — the last of the three same-id requests — may ever respond")
        XCTAssertEqual(router.keepAwakeModeSetCalls, [.display])
        guard case .success(_, let result) = responder.responses[0], case .snapshot = result else {
            return XCTFail("expected C's keepAwakeMode.set success response")
        }
    }

    /// `cancelAll()` called during the same "orphan window" (A superseded
    /// by B, A still resolving) must cancel whatever is currently tracked
    /// (B) without crashing or ever delivering a response for either A or
    /// B, and must leave the in-flight map empty afterward.
    func testCancelAllDuringOrphanWindowCancelsTheCurrentEntryAndDeliversNoResponses() async {
        let router = FakeCommandRouter()
        router.snapshotGetAwaitsSignal = true
        router.historyClearAwaitsSignal = true
        let responder = FakeResponder()
        let handler = BridgeMessageHandler(router: router, responder: responder)
        let sharedID = "550e8400-e29b-41d4-a716-446655440000"

        handler.handle(body: ["id": sharedID, "version": bridgeVersion, "method": "snapshot.get", "payload": [String: Any]()])
        for _ in 0..<50 where router.snapshotGetContinuation == nil {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }

        handler.handle(body: ["id": sharedID, "version": bridgeVersion, "method": "history.clear", "payload": [String: Any]()])
        for _ in 0..<50 where router.historyClearContinuation == nil {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }

        // cancelAll() during the orphan window — B is the currently
        // tracked (superseding) entry; A is already-orphaned but still
        // suspended.
        handler.cancelAll()

        router.resumeSnapshotGet()
        router.resumeHistoryClear()
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(responder.responses.count, 0, "cancelAll during the orphan window must suppress every pending response")
    }

    // MARK: - real WKWebView integration: the relay is reachable end-to-end from page-world script

    /// Resolves once a real `WKWebView` finishes loading, so the
    /// integration test below can `await` a load completing before
    /// driving page script against it.
    private final class LoadCompletionDelegate: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Never>?

        func waitForLoad() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let waiting = continuation
            continuation = nil
            waiting?.resume()
        }
    }

    /// End-to-end proof that a real page-world script — with no direct
    /// visibility of `window.webkit.messageHandlers.seerBridge` (never
    /// registered in `.page`) — can still reach `BridgeMessageHandler`
    /// purely through the DOM handoff: setting the exact fixed attribute
    /// and dispatching the exact fixed event, exactly as
    /// `renderer/bridge/dom-relay-port.ts` does, and exactly as
    /// `BridgeRelayUserScript` (injected by
    /// `BridgeMessageHandlerRegistration.register` into
    /// `BridgeContentWorld.bridge`) expects. This drives a real
    /// `WKWebView`/`WKUserContentController`/content-world registration —
    /// nothing here is faked — so it also exercises the exact
    /// `WKUserScript` this handler produces, not just its literal source
    /// string in isolation.
    func testRealWKWebViewPageWorldScriptReachesTheHandlerOnlyThroughTheIsolatedRelay() async throws {
        let router = FakeCommandRouter()
        router.snapshotGetOutcome = .success(makeSnapshot(appVersion: "9.9.9-relay-test"))
        let responder = FakeResponder()
        let handler = BridgeMessageHandler(router: router, responder: responder)

        let configuration = WKWebViewConfiguration()
        BridgeMessageHandlerRegistration.register(handler, on: configuration.userContentController)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        let navigationDelegate = LoadCompletionDelegate()
        webView.navigationDelegate = navigationDelegate

        // Page-world script only ever does what
        // `renderer/bridge/dom-relay-port.ts` does: JSON-encode a request,
        // stash it in the fixed attribute, dispatch the fixed
        // non-bubbling event with no detail. It never references
        // `window.webkit` at all.
        let html = """
        <!doctype html>
        <html>
          <body>
            <script>
              var request = {
                id: "550e8400-e29b-41d4-a716-446655440000",
                version: "\(bridgeVersion)",
                method: "snapshot.get",
                payload: {}
              };
              document.documentElement.setAttribute("\(BridgeRelayUserScript.attributeName)", JSON.stringify(request));
              document.documentElement.dispatchEvent(new Event("\(BridgeRelayUserScript.eventName)", { bubbles: false }));
            </script>
          </body>
        </html>
        """

        webView.loadHTMLString(html, baseURL: nil)
        await navigationDelegate.waitForLoad()
        await responder.waitForResponses(count: 1)

        XCTAssertEqual(router.snapshotGetCallCount, 1, "the routed command must have actually reached the router")
        guard case .success(let id, .snapshot(let snapshot)) = responder.responses[0] else {
            return XCTFail("expected a success response carrying the fake snapshot")
        }
        XCTAssertEqual(id, "550e8400-e29b-41d4-a716-446655440000")
        XCTAssertEqual(snapshot.appVersion, "9.9.9-relay-test")

        // The attribute must not be left behind on the page after the
        // relay script has consumed and removed it.
        let remainingAttribute = try await webView.evaluateJavaScript(
            "document.documentElement.getAttribute(\"\(BridgeRelayUserScript.attributeName)\")"
        )
        XCTAssertNil(remainingAttribute as? String)
    }

    /// A page-world script attempting `window.webkit.messageHandlers
    /// .seerBridge` directly — the exact thing this fix removes from the
    /// TS transport — must find it `undefined`: the handler is registered
    /// only in `BridgeContentWorld.bridge`, never `.page`, so page-world
    /// script has no visibility of it at all, even with the exact same
    /// `WKWebViewConfiguration`/registration used above.
    func testRealWKWebViewPageWorldScriptCannotSeeTheHandlerDirectly() async throws {
        let router = FakeCommandRouter()
        let responder = FakeResponder()
        let handler = BridgeMessageHandler(router: router, responder: responder)

        let configuration = WKWebViewConfiguration()
        BridgeMessageHandlerRegistration.register(handler, on: configuration.userContentController)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        let navigationDelegate = LoadCompletionDelegate()
        webView.navigationDelegate = navigationDelegate

        webView.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
        await navigationDelegate.waitForLoad()

        let seenFromPageWorld = try await webView.evaluateJavaScript(
            "typeof (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.seerBridge)"
        )
        XCTAssertEqual(seenFromPageWorld as? String, "undefined")
    }
}

