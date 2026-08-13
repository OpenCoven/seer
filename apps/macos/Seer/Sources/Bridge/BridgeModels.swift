import Foundation

/// Wire protocol version this native host implements. Must match
/// `BRIDGE_VERSION` in `renderer/bridge/types.ts` (`"seer.bridge.v1"`)
/// exactly — any request whose `version` field is anything else is
/// rejected as `invalid_version`, and every response/event this host emits
/// carries exactly this string.
public let bridgeVersion = "seer.bridge.v1"

/// Maximum accepted size, in bytes, of a raw bridge request body — checked
/// *before* any JSON decoding is attempted (see `BridgeRequestDecoder
/// .decode`), so an oversized payload never reaches `JSONDecoder` at all.
public let bridgeMaxMessageBytes = 64 * 1024

/// Maximum accepted length of a request `id` string. Ids are expected to be
/// UUID-shaped (`defaultBridgeIdGenerator` in the TS transport always emits
/// a v4-UUID-shaped 36-character string), but this bound is deliberately a
/// little more generous than exactly 36 so a reasonable, still-bounded id
/// is not rejected outright — while still closing off unbounded/
/// pathological ids.
public let bridgeMaxIdLength = 128

/// Closed set of methods the standalone native host understands. Mirrors
/// `BridgeMethod` in `renderer/bridge/standalone-renderer-bridge.ts`
/// exactly — one raw case per wire method string, nothing else accepted.
/// There is deliberately no case (and no decode path anywhere in this
/// file) for anything resembling a generic command/shell-execution
/// surface.
public enum BridgeMethod: String, Sendable, CaseIterable {
    case snapshotGet = "snapshot.get"
    case keepAwakeModeSet = "keepAwakeMode.set"
    case historyClear = "history.clear"
    case updatesCheck = "updates.check"
    case updatesOpen = "updates.open"
    case panelHide = "panel.hide"
    case appQuit = "app.quit"
}

/// Stable, deterministic error codes this bridge can report back to the
/// renderer. Messages paired with these codes must never include internal
/// file paths, stack traces, or other implementation detail.
public enum BridgeErrorCode: String, Sendable, Equatable {
    case messageTooLarge = "message_too_large"
    case invalidJSON = "invalid_json"
    case invalidRequest = "invalid_request"
    case invalidVersion = "invalid_version"
    case invalidPayload = "invalid_payload"
    case unknownMethod = "unknown_method"
    case commandFailed = "command_failed"
    case commandUnavailable = "command_unavailable"
}

/// Wire error payload sent back to the renderer for a failed request.
/// Mirrors `NativeBridgeErrorPayload` in
/// `renderer/bridge/standalone-renderer-bridge.ts` field-for-field.
public struct BridgeErrorPayload: Error, Equatable, Sendable {
    public let code: BridgeErrorCode
    public let message: String

    public init(code: BridgeErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

extension BridgeErrorPayload: Encodable {
    private enum CodingKeys: String, CodingKey { case code, message }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code.rawValue, forKey: .code)
        try container.encode(message, forKey: .message)
    }
}

/// Payload carried by a decoded request, one case per method matching
/// `BridgeMethodPayloadMap` in the TS source: parameterless methods carry
/// no data (their wire payload is `{}` exactly, encoded here as `.empty`),
/// `keepAwakeModeSet` carries its validated `mode`.
public enum BridgePayload: Equatable, Sendable {
    case empty
    case keepAwakeMode(KeepAwakeMode)
}

/// A fully validated, decoded inbound bridge request. The only way to
/// construct one is via `BridgeRequestDecoder.decode`, which enforces
/// every closed-shape rule described there — there is no public
/// initializer that bypasses that validation.
public struct BridgeRequest: Equatable, Sendable {
    public let id: String
    public let method: BridgeMethod
    public let payload: BridgePayload
}

/// Result carried inside a successful response: either a full `AppSnapshot`
/// or "no result" (wire-encoded as JSON `null`, matching `decodeVoidResult`
/// in the TS transport, which accepts only a literal `null` as a void
/// success — never an absent field, `undefined`, or empty object).
public enum BridgeResultPayload: Sendable {
    case snapshot(AppSnapshot)
    case none
}

extension BridgeResultPayload: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .snapshot(let snapshot):
            try container.encode(snapshot)
        case .none:
            try container.encodeNil()
        }
    }
}

/// The exact wire response envelope sent back to the renderer, matching
/// `BridgeSuccessResponse` / `BridgeErrorResponse` in the TS source: a
/// success response carries `result` and no `error` key; an error
/// response carries `error` and no `result` key.
public enum BridgeResponse: Sendable, Equatable {
    case success(id: String, result: BridgeResultPayload)
    case failure(id: String, error: BridgeErrorPayload)

    public var id: String {
        switch self {
        case .success(let id, _): return id
        case .failure(let id, _): return id
        }
    }

    public static func == (lhs: BridgeResponse, rhs: BridgeResponse) -> Bool {
        switch (lhs, rhs) {
        case let (.failure(lID, lError), .failure(rID, rError)):
            return lID == rID && lError == rError
        case let (.success(lID, .none), .success(rID, .none)):
            return lID == rID
        case let (.success(lID, .snapshot(lSnapshot)), .success(rID, .snapshot(rSnapshot))):
            return lID == rID && lSnapshot == rSnapshot
        default:
            return false
        }
    }
}

extension BridgeResponse: Encodable {
    private enum CodingKeys: String, CodingKey { case id, version, kind, ok, result, error }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bridgeVersion, forKey: .version)
        try container.encode("response", forKey: .kind)
        switch self {
        case .success(let id, let result):
            try container.encode(id, forKey: .id)
            try container.encode(true, forKey: .ok)
            try container.encode(result, forKey: .result)
        case .failure(let id, let error):
            try container.encode(id, forKey: .id)
            try container.encode(false, forKey: .ok)
            try container.encode(error, forKey: .error)
        }
    }
}

/// The exact wire event envelope for `snapshot.changed`, matching
/// `BridgeSnapshotChangedEvent` in the TS source.
public struct BridgeSnapshotChangedEvent: Encodable, Equatable, Sendable {
    public let snapshot: AppSnapshot

    public init(snapshot: AppSnapshot) {
        self.snapshot = snapshot
    }

    private enum CodingKeys: String, CodingKey { case version, kind, type, snapshot }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bridgeVersion, forKey: .version)
        try container.encode("event", forKey: .kind)
        try container.encode("snapshot.changed", forKey: .type)
        try container.encode(snapshot, forKey: .snapshot)
    }
}

/// A `CodingKey` that accepts any string — used only to enumerate/inspect
/// the keys actually present in a JSON object (for exact key-set
/// validation), never to decode a field's value with a loosened type.
struct AnyCodingKey: CodingKey, Equatable {
    let stringValue: String
    var intValue: Int? { nil }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}

/// Every way `BridgeRequestDecoder` can refuse to turn a raw request body
/// into a `BridgeRequest`. Thrown internally by `RawBridgeRequest.init`
/// before `BridgeRequestDecoder.validate` has even run — kept distinct
/// from `DecodingError` so `BridgeRequestDecoder.decode` can map each case
/// to its own stable `BridgeErrorCode` without re-inspecting a generic
/// `DecodingError`'s associated values. `.invalidPayload` carries the raw
/// (not-yet-validated) `id` string decoded just before the failure, so a
/// caller can still echo it back in a rejection response if it turns out
/// to pass `BridgeRequestDecoder`'s own id validation.
enum BridgeDecodingFailure: Error {
    case invalidRequest
    case invalidPayload(id: String)
}

/// Intermediate decode target used only by `BridgeRequestDecoder`.
/// Captures the request's top-level string fields plus the *key set* of
/// `payload` (not its values) — per-method payload field decoding happens
/// afterward in `BridgeRequestDecoder.validate`, once `method` (and
/// therefore the expected payload shape) is known, using `payloadDecoder`
/// positioned at that nested value. Deliberately never routes through a
/// loosely-typed `Any`/`NSNumber` intermediate for payload values: doing so
/// is exactly what would risk silently treating a JSON boolean as a JSON
/// number (or vice versa). Values are instead decoded directly by the
/// specific type each field expects (see `BridgeRequestDecoder
/// .keepAwakeModePayload`), which `JSONDecoder` only ever satisfies for a
/// token of that exact JSON type.
struct RawBridgeRequest: Decodable {
    let id: String
    let version: String
    let method: String
    let payloadKeys: Set<String>
    let payloadDecoder: Decoder

    private enum TopLevelKeys: String, CodingKey { case id, version, method, payload }

    init(from decoder: Decoder) throws {
        let anyContainer = try decoder.container(keyedBy: AnyCodingKey.self)
        let presentKeys = Set(anyContainer.allKeys.map(\.stringValue))
        let expectedKeys: Set<String> = ["id", "version", "method", "payload"]
        guard presentKeys == expectedKeys else {
            throw BridgeDecodingFailure.invalidRequest
        }

        let container = try decoder.container(keyedBy: TopLevelKeys.self)
        guard
            let idValue = try? container.decode(String.self, forKey: .id),
            let versionValue = try? container.decode(String.self, forKey: .version),
            let methodValue = try? container.decode(String.self, forKey: .method)
        else {
            throw BridgeDecodingFailure.invalidRequest
        }

        guard let payloadContainer = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: .payload) else {
            throw BridgeDecodingFailure.invalidPayload(id: idValue)
        }

        id = idValue
        version = versionValue
        method = methodValue
        payloadKeys = Set(payloadContainer.allKeys.map(\.stringValue))
        payloadDecoder = try container.superDecoder(forKey: .payload)
    }
}

/// Outcome of `BridgeRequestDecoder.decode`: either a fully validated
/// `BridgeRequest`, or a rejection paired with the request `id` to
/// correlate an error response to — but only when that `id` itself passed
/// validation. A request whose `id` field was missing, empty, too long, or
/// contained characters outside the allowed set has no trustworthy id to
/// respond with (`id: nil`): the caller drops it entirely, and the TS
/// transport's own pending request (if the malformed message even
/// corresponds to a real one) simply times out, exactly as if this
/// message had never arrived. Every other rejection reachable only after
/// the id already passed validation (`invalidVersion`, `unknownMethod`,
/// `invalidPayload` for a *known* method) always carries a non-nil `id`,
/// so the renderer's pending promise for it rejects immediately with a
/// typed `NativeBridgeRequestError` instead of waiting out the full
/// timeout.
enum BridgeDecodeOutcome {
    case accepted(BridgeRequest)
    case rejected(id: String?, error: BridgeErrorPayload)
}

/// Decodes and strictly validates a raw bridge request body into a
/// `BridgeRequest`, or a stable `BridgeErrorPayload` describing exactly why
/// it was rejected. Every check here is closed/exhaustive: unrecognized
/// top-level keys, an unrecognized `method`, a `payload` with the wrong key
/// set, or a field of the wrong JSON type are all rejected — never
/// coerced, widened, or silently ignored.
enum BridgeRequestDecoder {
    static func decode(data: Data) -> BridgeDecodeOutcome {
        // Checked first, before any JSON parsing/decoding is attempted at
        // all: an oversized body never reaches `JSONDecoder`.
        guard data.count <= bridgeMaxMessageBytes else {
            return .rejected(
                id: nil,
                error: BridgeErrorPayload(code: .messageTooLarge, message: "Bridge request exceeded the maximum allowed size")
            )
        }

        do {
            let raw = try JSONDecoder().decode(RawBridgeRequest.self, from: data)
            return validate(raw)
        } catch let failure as BridgeDecodingFailure {
            switch failure {
            case .invalidRequest:
                return .rejected(
                    id: nil,
                    error: BridgeErrorPayload(code: .invalidRequest, message: "Bridge request had an unexpected shape")
                )
            case .invalidPayload(let candidateID):
                let echoID = isValidId(candidateID) ? candidateID : nil
                return .rejected(
                    id: echoID,
                    error: BridgeErrorPayload(code: .invalidPayload, message: "Bridge request payload had an unexpected shape")
                )
            }
        } catch let error as DecodingError {
            if case .dataCorrupted = error {
                return .rejected(id: nil, error: BridgeErrorPayload(code: .invalidJSON, message: "Bridge request was not valid JSON"))
            }
            // The decoder reached `RawBridgeRequest.init` at all, so the
            // bytes were valid JSON — this means the root value itself was
            // not a JSON object (e.g. an array or a scalar).
            return .rejected(
                id: nil,
                error: BridgeErrorPayload(code: .invalidRequest, message: "Bridge request must be a JSON object")
            )
        } catch {
            return .rejected(id: nil, error: BridgeErrorPayload(code: .invalidJSON, message: "Bridge request was not valid JSON"))
        }
    }

    private static func validate(_ raw: RawBridgeRequest) -> BridgeDecodeOutcome {
        guard isValidId(raw.id) else {
            return .rejected(
                id: nil,
                error: BridgeErrorPayload(code: .invalidRequest, message: "Bridge request id was missing, empty, or malformed")
            )
        }
        guard raw.version == bridgeVersion else {
            return .rejected(
                id: raw.id,
                error: BridgeErrorPayload(code: .invalidVersion, message: "Bridge request version did not match")
            )
        }
        guard let method = BridgeMethod(rawValue: raw.method) else {
            return .rejected(
                id: raw.id,
                error: BridgeErrorPayload(code: .unknownMethod, message: "Bridge request method was not recognized")
            )
        }

        switch method {
        case .keepAwakeModeSet:
            guard raw.payloadKeys == ["mode"] else {
                return .rejected(
                    id: raw.id,
                    error: BridgeErrorPayload(
                        code: .invalidPayload,
                        message: "keepAwakeMode.set payload must contain exactly the field \"mode\""
                    )
                )
            }
            guard let mode = keepAwakeModePayload(from: raw.payloadDecoder) else {
                return .rejected(
                    id: raw.id,
                    error: BridgeErrorPayload(
                        code: .invalidPayload,
                        message: "keepAwakeMode.set payload's \"mode\" must be exactly \"system\" or \"display\""
                    )
                )
            }
            return .accepted(BridgeRequest(id: raw.id, method: method, payload: .keepAwakeMode(mode)))
        case .snapshotGet, .historyClear, .updatesCheck, .updatesOpen, .panelHide, .appQuit:
            guard raw.payloadKeys.isEmpty else {
                return .rejected(
                    id: raw.id,
                    error: BridgeErrorPayload(code: .invalidPayload, message: "\(method.rawValue) payload must be exactly {}")
                )
            }
            return .accepted(BridgeRequest(id: raw.id, method: method, payload: .empty))
        }
    }

    private enum KeepAwakeModePayloadKeys: String, CodingKey { case mode }

    /// Decodes `payload.mode` strictly as a JSON string (never a number,
    /// boolean, `null`, array, or object) and only then attempts to parse
    /// it as one of the two closed `KeepAwakeMode` raw values.
    private static func keepAwakeModePayload(from payloadDecoder: Decoder) -> KeepAwakeMode? {
        guard
            let container = try? payloadDecoder.container(keyedBy: KeepAwakeModePayloadKeys.self),
            let modeString = try? container.decode(String.self, forKey: .mode)
        else {
            return nil
        }
        return KeepAwakeMode(rawValue: modeString)
    }

    /// Ids are expected to be UUID-shaped, but this accepts any nonempty,
    /// bounded-length string made up only of ASCII letters, digits, and
    /// `-` — a superset of UUID syntax that still closes off unbounded or
    /// control-character-laden ids.
    private static func isValidId(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= bridgeMaxIdLength else { return false }
        return id.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "-")
        }
    }
}
