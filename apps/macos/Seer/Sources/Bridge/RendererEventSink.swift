import Foundation
import WebKit

/// The minimal JavaScript-calling capability `RendererEventSink` needs.
/// `WKWebView` conforms via the extension below; tests inject a fake so no
/// real `WKWebView`/WebKit navigation is ever required to exercise the
/// sink's own delivery logic — `WKWebView`'s methods are otherwise hard to
/// mock directly.
@MainActor
public protocol JavaScriptCalling: AnyObject {
    func callAsyncJavaScript(
        _ functionBody: String,
        arguments: [String: Any],
        contentWorld: WKContentWorld
    ) async throws -> Any?
}

extension WKWebView: JavaScriptCalling {
    public func callAsyncJavaScript(
        _ functionBody: String,
        arguments: [String: Any],
        contentWorld: WKContentWorld
    ) async throws -> Any? {
        try await callAsyncJavaScript(functionBody, arguments: arguments, in: nil, contentWorld: contentWorld)
    }
}

/// Delivers responses/events to the renderer's `window.seerNative.receive`
/// global — the *only* JavaScript this sink ever calls, and always through
/// `callAsyncJavaScript` with a structured JSON argument, never string
/// interpolation or `evaluateJavaScript`. Conforms to both
/// `AppSnapshotRendererSink` (Task 9's `snapshot.changed` event path) and
/// `BridgeResponding` (Task 10's request/response path) since both
/// ultimately deliver one JSON object to that same renderer-side global.
@MainActor
public final class RendererEventSink: AppSnapshotRendererSink, BridgeResponding {
    /// Every way delivering a message to the renderer can fail. Reported
    /// via `onDeliveryFailure` as a typed diagnostic — never silently
    /// swallowed as if delivery had succeeded.
    public enum DeliveryFailure: Error {
        /// The web view this sink was constructed with has already been
        /// deallocated (or the sink was never wired to one) — there is
        /// nowhere to deliver the message.
        case webViewUnavailable
        /// `callAsyncJavaScript` itself threw — e.g. the page navigated
        /// away, failed to load, or the call otherwise could not
        /// complete. Wraps the underlying error.
        case javaScriptCallFailed(Error)
        /// The response/event value could not be encoded into a
        /// JSON-serializable argument. Should not occur for any closed
        /// `BridgeResponse`/`BridgeSnapshotChangedEvent` value, but guarded
        /// rather than force-unwrapped.
        case encodingFailed(Error)
    }

    private weak var javaScriptCaller: (any JavaScriptCalling)?
    private let onDeliveryFailure: (DeliveryFailure) -> Void

    public init(
        javaScriptCaller: any JavaScriptCalling,
        onDeliveryFailure: @escaping (DeliveryFailure) -> Void = { _ in }
    ) {
        self.javaScriptCaller = javaScriptCaller
        self.onDeliveryFailure = onDeliveryFailure
    }

    /// `AppSnapshotCoordinator`'s `AppSnapshotRendererSink` conformance:
    /// delivers the exact `snapshot.changed` event envelope.
    public func emit(_ snapshot: AppSnapshot) {
        deliver(BridgeSnapshotChangedEvent(snapshot: snapshot))
    }

    /// `BridgeMessageHandler`'s `BridgeResponding` conformance: delivers a
    /// routed request's response envelope.
    public func deliverResponse(_ response: BridgeResponse) {
        deliver(response)
    }

    private func deliver(_ payload: Encodable) {
        guard let caller = javaScriptCaller else {
            onDeliveryFailure(.webViewUnavailable)
            return
        }

        let arguments: [String: Any]
        do {
            arguments = ["message": try Self.jsonObject(from: payload)]
        } catch {
            onDeliveryFailure(.encodingFailed(error))
            return
        }

        Task { [onDeliveryFailure] in
            do {
                _ = try await caller.callAsyncJavaScript(
                    "window.seerNative.receive(message)",
                    arguments: arguments,
                    contentWorld: .page
                )
            } catch {
                onDeliveryFailure(.javaScriptCallFailed(error))
            }
        }
    }

    private static func jsonObject(from value: Encodable) throws -> Any {
        let data = try JSONEncoder().encode(AnyEncodableBox(value))
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}

/// Type-erasing box so `RendererEventSink.deliver(_:)` can encode any
/// concrete `Encodable` payload (`BridgeResponse`, `BridgeSnapshotChangedEvent`)
/// through one code path.
private struct AnyEncodableBox: Encodable {
    private let encodeClosure: (Encoder) throws -> Void

    init(_ value: Encodable) {
        encodeClosure = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeClosure(encoder)
    }
}
