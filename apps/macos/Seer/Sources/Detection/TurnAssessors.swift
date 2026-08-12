import Foundation

/// Pure turn classifiers ported from `main/services/agent-detection-policy.ts`.
/// See that module for the shared detection-policy contract:
/// - Prefer session/transcript turn state over process presence.
/// - Idle agent processes (terminal open, waiting for input) must NOT keep the Mac awake.
/// - Process CPU alone is never enough for agents that leave daemons running.
///
/// A loosely-typed JSON object, mirroring TypeScript's `Record<string, unknown>`
/// / `unknown` event shapes. Session/fixture JSON is parsed with
/// `JSONSerialization` (not `Decodable`) so every classifier can tolerate
/// partial or unexpected shapes exactly like the TS `asRecord` helper does.
public typealias JSONObject = [String: Any]

public let sessionCandidateWindowMs: Int64 = 10 * 60_000
public let turnActiveGraceMs: Int64 = 45_000
public let toolTurnGraceMs: Int64 = 3 * 60_000
/// Codex writes explicit turn boundaries (task_started … task_complete), so an
/// open turn can be trusted far longer than a bare event — long builds/tests can
/// run for minutes without a single rollout write. Bounded so a crashed app
/// can't caffeinate forever (the 10 min candidate window caps it anyway).
/// Grok CLI brackets every turn with turn_started … turn_ended in events.jsonl
/// and shares this exact grace window (`CODEX_OPEN_TURN_GRACE_MS` ==
/// `GROK_OPEN_TURN_GRACE_MS` in the TypeScript source).
public let openTurnGraceMs: Int64 = 8 * 60_000
/// Shared by Codex and Grok tail-quiet fallbacks (`CODEX_TAIL_QUIET_MS` ==
/// `GROK_TAIL_QUIET_MS` in the TypeScript source).
public let openTurnQuietTailMs: Int64 = 15_000
public let processOnlyCPUThreshold: Double = 25.0
/// Generic logs only get a short window — better false negatives than caffeinating idle CLIs.
public let genericMtimeWindowMs: Int64 = 20_000

// MARK: - Numeric/timestamp helpers

/// Distinguishes a JSON boolean from a JSON number: `JSONSerialization`
/// represents both as `NSNumber`, but the TS reference's `typeof value ===
/// "number"` check must reject booleans.
func isBooleanNumber(_ number: NSNumber) -> Bool {
    CFGetTypeID(number) == CFBooleanGetTypeID()
}

/// Extracts a finite `Double` from an `Any?`, rejecting JSON booleans and
/// non-finite values, mirroring `typeof value === "number" &&
/// Number.isFinite(value)` in the TS reference.
func finiteNumber(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber, !isBooleanNumber(number) else { return nil }
    let doubleValue = number.doubleValue
    return doubleValue.isFinite ? doubleValue : nil
}

/// Parses an ISO 8601 timestamp (with or without fractional seconds) to Unix
/// milliseconds, mirroring `Date.parse` for the timestamp formats every
/// fixture and session format in this corpus uses.
func parseISO8601ToMs(_ text: String) -> Int64? {
    let withFractional = ISO8601DateFormatter()
    withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFractional.date(from: text) {
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    if let date = plain.date(from: text) {
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    return nil
}

/// Mirrors `parseTimestamp` in the TS policy: a finite JSON number greater
/// than 1e12 is already milliseconds, a smaller finite number is seconds; a
/// non-empty string is parsed as an ISO 8601 timestamp; anything else falls
/// back to `fallbackMs`.
public func parseTimestamp(_ value: Any?, fallbackMs: Int64) -> Int64 {
    if let doubleValue = finiteNumber(value) {
        return doubleValue > 1e12 ? Int64(doubleValue) : Int64(doubleValue * 1000)
    }
    if let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        if let parsedMs = parseISO8601ToMs(text) {
            return parsedMs
        }
    }
    return fallbackMs
}

/// Mirrors `asRecord` in the TS policy.
func asRecord(_ value: Any?) -> JSONObject? {
    value as? JSONObject
}

/// Returns the first of `values` that is neither Swift `nil` nor a JSON
/// `null` (`NSNull`), mirroring JavaScript's `??` nil-coalescing operator
/// over `unknown` values that may be `null`.
func firstNonNull(_ values: Any?...) -> Any? {
    for value in values {
        if let value, !(value is NSNull) {
            return value
        }
    }
    return nil
}

// MARK: - Friendly labels/activity

private let titleCaseSeparators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "_./"))

/// True for a non-empty run of ASCII uppercase letters/digits only, mirroring
/// the TS regex `/^[A-Z0-9]{2,}$/` exactly (not Unicode-aware `isUppercase`).
private func isAsciiUpperOrDigitRun(_ word: String, minimumLength: Int) -> Bool {
    guard word.count >= minimumLength else { return false }
    return word.unicodeScalars.allSatisfy { scalar in
        (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 48 && scalar.value <= 57)
    }
}

public func titleCaseWords(_ raw: String) -> String {
    let words = raw.components(separatedBy: titleCaseSeparators).filter { !$0.isEmpty }
    let mapped = words.map { word -> String in
        if isAsciiUpperOrDigitRun(word, minimumLength: 2) { return word }
        if word.count <= 2 && word == word.lowercased() { return word }
        return word.prefix(1).uppercased() + word.dropFirst()
    }
    return mapped.joined(separator: " ")
}

/// Turn path slugs / bundle ids into short display names, mirroring
/// `humanizeProjectName` in the TS policy.
public func humanizeProjectName(_ raw: String) -> String {
    var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty { return "" }

    // my-project-local-1pwq7g9n → my-project
    value = replacingRegex(value, pattern: #"-local-[a-z0-9]+$"#, options: [.caseInsensitive], with: "")
    // strip trailing build-ish ids
    value = replacingRegex(value, pattern: #"-[a-f0-9]{6,}$"#, options: [.caseInsensitive], with: "")
    value = replacingRegex(value, pattern: #"[_./]+"#, with: "-")
    value = replacingRegex(value, pattern: #"-+"#, with: "-")
    value = replacingRegex(value, pattern: #"^-|-$"#, with: "")

    let titled = titleCaseWords(value.replacingOccurrences(of: "-", with: " "))
    return titled.isEmpty ? raw : titled
}

private func replacingRegex(
    _ text: String,
    pattern: String,
    options: NSRegularExpression.Options = [],
    with template: String
) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
}

/// Grok sessions live at .grok/sessions/<url-encoded cwd>/<session id>/events.jsonl.
public func grokProjectLabel(_ filePath: String) -> String {
    let parts = filePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 3 else { return "" }
    let encodedCwd = parts[parts.count - 3]
    if encodedCwd.isEmpty { return "" }

    guard let decoded = encodedCwd.removingPercentEncoding else { return "" }

    let trimmed = trimmingTrailingSlashes(decoded)
    let base = lastPathSegment(trimmed)
    return base.isEmpty ? "" : humanizeProjectName(base)
}

private func trimmingTrailingSlashes(_ text: String) -> String {
    replacingRegex(text, pattern: #"[/\\]+$"#, with: "")
}

private func lastPathSegment(_ text: String) -> String {
    let parts = text.split(separator: "/", omittingEmptySubsequences: false)
    return parts.last.map(String.init) ?? text
}

public func friendlySessionLabel(_ filePath: String) -> String {
    let parts = filePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    let file = parts.last ?? "session"
    let parent = parts.count >= 2 ? parts[parts.count - 2] : ""

    // Grok's session id folder is a uuid — the project comes from the encoded cwd above it.
    if file == "events.jsonl" { return grokProjectLabel(filePath) }

    // Codex rollouts live under sessions/YYYY/MM/DD — the project comes from the
    // session's cwd instead, so don't label the agent with a date folder.
    if file.hasPrefix("rollout-") { return "" }

    if parent.hasPrefix("-") {
        let withoutLeading = String(parent.dropFirst())
        let primary = withoutLeading.components(separatedBy: "--").first ?? withoutLeading
        let segments = primary.split(separator: "-").map(String.init).filter { !$0.isEmpty }

        if let appsIdx = segments.lastIndex(of: "apps"), appsIdx < segments.count - 1 {
            return humanizeProjectName(segments[(appsIdx + 1)...].joined(separator: "-"))
        }

        if let codeIdx = segments.lastIndex(of: "Code"), codeIdx < segments.count - 1 {
            return humanizeProjectName(segments[(codeIdx + 1)...].joined(separator: "-"))
        }

        let tail = segments.suffix(3).joined(separator: "-")
        let humanized = humanizeProjectName(tail)
        return humanized.isEmpty ? "Project" : humanized
    }

    if !parent.isEmpty, parent != "sessions", parent != "projects" {
        return humanizeProjectName(parent)
    }

    let withoutExtension = replacingRegex(file, pattern: #"\.jsonl?$"#, options: [.caseInsensitive], with: "")
    let humanized = humanizeProjectName(withoutExtension)
    return humanized.isEmpty ? "Session" : humanized
}

/// Internal turn reasons → short, human activity copy, mirroring
/// `friendlyActivity` in the TS policy.
public func friendlyActivity(_ reason: String?, processOnly: Bool) -> String {
    if processOnly { return "Busy" }
    guard let reason, !reason.isEmpty else { return "Working" }

    let normalized = reason.lowercased()
    if normalized.contains("tool_use") || normalized.contains("tool_call") || normalized.contains("function_call") {
        return "Running tools"
    }
    if normalized.contains("awaiting model") || normalized.contains("tool result") {
        return "Thinking"
    }
    if normalized.contains("reasoning") || normalized.contains("thinking") {
        return "Thinking"
    }
    if normalized.contains("assistant") || normalized.contains("agent_message") || normalized.contains("agent_reasoning") {
        return "Writing"
    }
    if normalized.contains("user prompt") || normalized.contains("started") {
        return "Started"
    }
    if normalized.contains("streaming") { return "Writing" }
    if normalized.contains("generating") || normalized.contains("continuation") {
        return "Writing"
    }
    if normalized.contains("recent session") { return "Active" }
    if normalized.hasPrefix("stale") { return "Wrapping up" }
    return "Working"
}

public func buildFriendlyDetail(projectLabel: String?, reason: String? = nil, processOnly: Bool = false) -> String {
    let activity = friendlyActivity(reason, processOnly: processOnly)
    if let projectLabel, !projectLabel.isEmpty {
        return "\(projectLabel) · \(activity)"
    }
    return activity
}

// MARK: - Turn assessment

public struct TurnAssessment: Equatable, Sendable {
    public var active: Bool
    public var lastActivityAt: Int64
    public var reason: String
    /// Present when the assessor derived a project label directly from the
    /// session content (e.g. Codex's `cwd` payload) rather than the
    /// filesystem path.
    public var label: String?

    public init(active: Bool, lastActivityAt: Int64, reason: String, label: String? = nil) {
        self.active = active
        self.lastActivityAt = lastActivityAt
        self.reason = reason
        self.label = label
    }
}

private let claudeMetadataTypes: Set<String> = [
    "last-prompt",
    "mode",
    "permission-mode",
    "queue-operation",
    "ai-title",
    "custom-title",
    "agent-name",
    "pr-link",
    "file-history-snapshot",
]

/// Mirrors `assessClaudeTurn` in the TS policy.
public func assessClaudeTurn(_ events: [JSONObject], mtimeMs: Int64, now: Int64) -> TurnAssessment {
    var index = events.count - 1
    while index >= 0 {
        defer { index -= 1 }
        let record = events[index]
        let type = record["type"] as? String ?? ""

        if claudeMetadataTypes.contains(type) { continue }

        let timestamp = parseTimestamp(record["timestamp"], fallbackMs: mtimeMs)
        let age = now - timestamp

        if type == "system" {
            let subtype = record["subtype"] as? String ?? ""
            if subtype == "turn_duration" || subtype == "away_summary" {
                return TurnAssessment(active: false, lastActivityAt: timestamp, reason: "turn ended (\(subtype))")
            }
            continue
        }

        if type == "assistant" {
            let message = asRecord(record["message"])
            let stopReason = (message?["stop_reason"] as? String) ?? (record["stop_reason"] as? String) ?? ""

            if stopReason == "end_turn" || stopReason == "stop_sequence" {
                return TurnAssessment(active: false, lastActivityAt: timestamp, reason: "end_turn")
            }

            if stopReason == "tool_use" {
                let active = age <= toolTurnGraceMs
                return TurnAssessment(
                    active: active,
                    lastActivityAt: timestamp,
                    reason: active ? "tool_use in progress" : "stale tool_use"
                )
            }

            // Streaming / incomplete assistant chunk without an end marker.
            let active = age <= turnActiveGraceMs
            return TurnAssessment(
                active: active,
                lastActivityAt: timestamp,
                reason: active ? "assistant output" : "stale assistant output"
            )
        }

        if type == "user" {
            let hasToolResult = record["toolUseResult"] != nil
            if hasToolResult {
                let active = age <= toolTurnGraceMs
                return TurnAssessment(
                    active: active,
                    lastActivityAt: timestamp,
                    reason: active ? "awaiting model after tool" : "stale tool result"
                )
            }

            // Fresh human prompt starts a turn.
            let active = age <= turnActiveGraceMs
            return TurnAssessment(
                active: active,
                lastActivityAt: timestamp,
                reason: active ? "user prompt" : "stale user prompt"
            )
        }
    }

    // No turn events — file touch alone is not work.
    return TurnAssessment(active: false, lastActivityAt: mtimeMs, reason: "no turn events")
}

// MARK: - Codex

/// Codex rollout events that open a turn (both CLI and Codex Desktop).
private let codexTurnStartEvents: Set<String> = ["task_started", "user_message", "user_input"]
/// Events that close a turn.
private let codexTurnEndEvents: Set<String> = ["task_complete", "turn_aborted", "turn_failed", "shutdown_complete"]
/// Model output in progress.
private let codexStreamEvents: Set<String> = [
    "agent_message",
    "agent_message_delta",
    "agent_message_content_delta",
    "agent_reasoning",
    "agent_reasoning_delta",
    "agent_reasoning_section_break",
    "agent_reasoning_raw_content",
    "agent_reasoning_raw_content_delta",
]
/// The turn is parked on a human decision — that is not the agent working.
private let codexApprovalEvents: Set<String> = [
    "exec_approval_request",
    "apply_patch_approval_request",
    "elicitation_request",
]
/// Bookkeeping that says nothing about whether a turn is running.
private let codexMetaEvents: Set<String> = [
    "token_count",
    "thread_settings_applied",
    "session_configured",
    "notification",
    "background_event",
]

enum CodexSignalRole: Equatable {
    case start, end, stream, tool, awaitUser, meta
}

struct CodexSignal {
    let role: CodexSignalRole
    let kind: String
    let at: Int64
}

/// Tool traffic keeps arriving under new names — match the shape, not a fixed list.
func isCodexToolEventName(_ name: String) -> Bool {
    guard let regex = try? NSRegularExpression(pattern: #"(_begin|_end|_delta|_call|_output|_result)$"#) else {
        return false
    }
    let range = NSRange(name.startIndex..<name.endIndex, in: name)
    return regex.firstMatch(in: name, options: [], range: range) != nil
}

func classifyCodexEvent(_ record: JSONObject) -> (role: CodexSignalRole, kind: String) {
    let type = record["type"] as? String ?? ""
    let payload = asRecord(record["payload"])
    let payloadType = (payload?["type"] as? String) ?? ""

    if type == "event_msg" {
        if codexMetaEvents.contains(payloadType) { return (.meta, payloadType) }
        if codexTurnEndEvents.contains(payloadType) { return (.end, payloadType) }
        if codexTurnStartEvents.contains(payloadType) { return (.start, payloadType) }
        if codexApprovalEvents.contains(payloadType) { return (.awaitUser, payloadType) }
        if codexStreamEvents.contains(payloadType) { return (.stream, payloadType) }
        if isCodexToolEventName(payloadType) { return (.tool, payloadType) }
        return (.meta, payloadType.isEmpty ? type : payloadType)
    }

    if type == "response_item" {
        if payloadType == "reasoning" { return (.stream, "agent_reasoning") }
        if payloadType == "message" {
            let role = (payload?["role"] as? String) ?? ""
            if role == "assistant" { return (.stream, "agent_message") }
            if role == "user" { return (.start, "user_message") }
            return (.meta, "message")
        }
        if isCodexToolEventName(payloadType) { return (.tool, payloadType) }
        return (.meta, payloadType.isEmpty ? type : payloadType)
    }

    return (.meta, type)
}

func codexSignalReason(_ signal: CodexSignal?) -> String {
    guard let signal else { return "turn in progress" }
    if signal.role == .tool {
        guard let regex = try? NSRegularExpression(pattern: #"(_end|_output|_result)$"#) else {
            return "tool_call \(signal.kind)"
        }
        let range = NSRange(signal.kind.startIndex..<signal.kind.endIndex, in: signal.kind)
        let matches = regex.firstMatch(in: signal.kind, options: [], range: range) != nil
        return matches ? "awaiting model after tool" : "tool_call \(signal.kind)"
    }
    if signal.role == .stream { return signal.kind }
    return "user prompt"
}

/// Codex records the working directory in session_meta / turn_context.
public func codexProjectLabelFromPath(_ cwd: String) -> String? {
    let trimmed = trimmingTrailingSlashes(cwd)
    let base = lastPathSegment(trimmed)
    return base.isEmpty ? nil : humanizeProjectName(base)
}

public func codexProjectLabel(_ events: [JSONObject]) -> String? {
    var index = events.count - 1
    while index >= 0 {
        defer { index -= 1 }
        let record = events[index]
        let payload = asRecord(record["payload"])
        let cwd = (payload?["cwd"] as? String) ?? (record["cwd"] as? String) ?? ""
        if !cwd.isEmpty, let label = codexProjectLabelFromPath(cwd) {
            return label
        }
    }
    return nil
}

/// Codex (CLI and Desktop) brackets every turn with task_started … task_complete.
/// Reading only the newest event misses whole phases — the gap between a prompt
/// and the first reasoning chunk, or a long shell command — so track the turn
/// boundaries instead and use the newest signal only for the status wording.
public func assessCodexTurn(_ events: [JSONObject], mtimeMs: Int64, now: Int64) -> TurnAssessment {
    let label = codexProjectLabel(events)

    var startedAt: Int64 = -1
    var endedAt: Int64 = -1
    var lastActivityAt: Int64 = -1
    var latest: CodexSignal?

    for record in events {
        let (role, kind) = classifyCodexEvent(record)
        if role == .meta { continue }

        let at = parseTimestamp(record["timestamp"], fallbackMs: mtimeMs)
        if at > lastActivityAt { lastActivityAt = at }
        if role == .start, at > startedAt { startedAt = at }
        if role == .end, at > endedAt { endedAt = at }
        if latest == nil || at >= latest!.at { latest = CodexSignal(role: role, kind: kind, at: at) }
    }

    if lastActivityAt < 0 {
        // Tail held nothing recognizable (huge single records) — trust fresh writes only.
        let age = now - mtimeMs
        let active = age <= openTurnQuietTailMs
        return TurnAssessment(
            active: active,
            lastActivityAt: mtimeMs,
            reason: active ? "recent session write" : "no turn events",
            label: label
        )
    }

    let age = now - lastActivityAt

    if latest?.role == .awaitUser {
        return TurnAssessment(active: false, lastActivityAt: lastActivityAt, reason: "waiting for approval", label: label)
    }

    if startedAt > endedAt {
        let active = age <= openTurnGraceMs
        let reason = codexSignalReason(latest)
        return TurnAssessment(
            active: active,
            lastActivityAt: lastActivityAt,
            reason: active ? reason : "stale \(reason)",
            label: label
        )
    }

    // Turn is closed; only output written after the end marker still counts.
    if let latest, latest.at > endedAt, latest.role == .stream || latest.role == .tool {
        let grace = latest.role == .tool ? toolTurnGraceMs : turnActiveGraceMs
        let reason = codexSignalReason(latest)
        return TurnAssessment(active: age <= grace, lastActivityAt: lastActivityAt, reason: reason, label: label)
    }

    return TurnAssessment(
        active: false,
        lastActivityAt: lastActivityAt,
        reason: endedAt >= 0 ? "turn complete" : "idle",
        label: label
    )
}

// MARK: - Grok

enum GrokSignalRole: Equatable {
    case start, end, stream, tool, awaitUser, meta
}

struct GrokSignal {
    let role: GrokSignalRole
    let kind: String
    let at: Int64
}

private let grokPhaseSignals: [String: (role: GrokSignalRole, kind: String)] = [
    "waiting_for_model": (.stream, "awaiting model"),
    "streaming_reasoning": (.stream, "reasoning"),
    "streaming_text": (.stream, "streaming text"),
    "tool_execution": (.tool, "tool_call"),
    "permission_prompt": (.awaitUser, "permission prompt"),
]

func classifyGrokEvent(_ record: JSONObject) -> (role: GrokSignalRole, kind: String) {
    let type = record["type"] as? String ?? ""
    let toolName = record["tool_name"] as? String ?? ""

    switch type {
    case "turn_started":
        return (.start, "user prompt")
    case "turn_ended":
        return (.end, "turn complete")
    case "permission_requested":
        return (.awaitUser, "permission prompt")
    case "permission_resolved", "loop_started", "first_token":
        return (.stream, "awaiting model")
    case "tool_started":
        return (.tool, toolName.isEmpty ? "tool_call" : "tool_call \(toolName)")
    case "tool_completed":
        return (.tool, "awaiting model after tool")
    case "phase_changed":
        let phase = record["phase"] as? String ?? ""
        return grokPhaseSignals[phase] ?? (.meta, phase.isEmpty ? "phase" : phase)
    default:
        return (.meta, type)
    }
}

/// Grok CLI ("grok", incl. the grok-build fork) writes turn_started … turn_ended plus
/// fine-grained phase_changed events. Turn boundaries decide active/idle; the newest
/// signal only picks the status wording. An unresolved permission_requested means Grok
/// is waiting on the human, which must never keep the Mac awake.
public func assessGrokTurn(_ events: [JSONObject], mtimeMs: Int64, now: Int64) -> TurnAssessment {
    var startedAt: Int64 = -1
    var endedAt: Int64 = -1
    var lastActivityAt: Int64 = -1
    var latest: GrokSignal?

    for record in events {
        let (role, kind) = classifyGrokEvent(record)
        if role == .meta { continue }

        let at = parseTimestamp(record["ts"], fallbackMs: mtimeMs)
        if at > lastActivityAt { lastActivityAt = at }
        if role == .start, at > startedAt { startedAt = at }
        if role == .end, at > endedAt { endedAt = at }
        if latest == nil || at >= latest!.at { latest = GrokSignal(role: role, kind: kind, at: at) }
    }

    if lastActivityAt < 0 {
        let age = now - mtimeMs
        let active = age <= openTurnQuietTailMs
        return TurnAssessment(
            active: active,
            lastActivityAt: mtimeMs,
            reason: active ? "recent session write" : "no turn events"
        )
    }

    let age = now - lastActivityAt
    let reason = latest?.kind ?? "turn in progress"

    if latest?.role == .awaitUser {
        return TurnAssessment(active: false, lastActivityAt: lastActivityAt, reason: "waiting for approval")
    }

    if startedAt > endedAt {
        let active = age <= openTurnGraceMs
        return TurnAssessment(
            active: active,
            lastActivityAt: lastActivityAt,
            reason: active ? reason : "stale \(reason)"
        )
    }

    // Long streaming turns emit thousands of phase events, so the tail can begin after
    // turn_started. Fall back to the newest signal with the short grace instead.
    let noBoundaryInTail = startedAt < 0 && endedAt < 0
    let outputAfterEnd = latest != nil && latest!.at > endedAt

    if (noBoundaryInTail || outputAfterEnd), let latest, latest.role == .stream || latest.role == .tool {
        let grace = latest.role == .tool ? toolTurnGraceMs : turnActiveGraceMs
        return TurnAssessment(active: age <= grace, lastActivityAt: lastActivityAt, reason: reason)
    }

    return TurnAssessment(active: false, lastActivityAt: lastActivityAt, reason: endedAt >= 0 ? "turn complete" : "idle")
}

// MARK: - Generic mtime

public func assessGenericMtime(mtimeMs: Int64, now: Int64) -> TurnAssessment {
    let age = now - mtimeMs
    let active = age <= genericMtimeWindowMs
    return TurnAssessment(
        active: active,
        lastActivityAt: mtimeMs,
        reason: active ? "recent session write" : "stale session write"
    )
}

// MARK: - Cursor

// NOTE: "inProgress" (mixed case) is preserved verbatim from
// `CURSOR_RUNNING_TOOL_STATUSES` in the TS policy even though `toolStatus`/
// `shellStatus` are always lowercased before this set is checked — meaning
// that entry never actually matches in either implementation. This is a
// faithful, intentional port of that quirk, not a fix.
private let cursorRunningToolStatuses: Set<String> = ["loading", "running", "pending", "in_progress", "inProgress"]

private func isLongHexIdentifier(_ text: String) -> Bool {
    guard text.count >= 16 else { return false }
    return text.unicodeScalars.allSatisfy { scalar in
        (scalar.value >= 48 && scalar.value <= 57) // 0-9
            || (scalar.value >= 97 && scalar.value <= 102) // a-f
            || (scalar.value >= 65 && scalar.value <= 70) // A-F
    }
}

public func cursorProjectLabel(_ record: JSONObject) -> String? {
    if let workspace = asRecord(record["workspaceIdentifier"]) {
        var fsPath: String?
        if let uri = asRecord(workspace["uri"]) {
            if let path = uri["fsPath"] as? String, !path.isEmpty {
                fsPath = path
            } else if let path = uri["path"] as? String, !path.isEmpty {
                fsPath = path
            }
        }
        if fsPath == nil, let wsId = workspace["id"] as? String, !isLongHexIdentifier(wsId) {
            fsPath = wsId
        }
        if let fsPath, !fsPath.isEmpty {
            let base = lastPathSegment(trimmingTrailingSlashes(fsPath))
            if !base.isEmpty { return humanizeProjectName(base) }
        }
    }

    if let name = record["name"] as? String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
    }
    return nil
}

func cursorHeaderGrouping(_ header: JSONObject) -> JSONObject {
    asRecord(header["grouping"]) ?? [:]
}

/// Cursor often leaves composer status stuck at "completed" on disk while a turn
/// is still running (especially during shell/tool waits). Prefer conversation
/// headers: an open user turn without turnDurationMs, or a tool still loading.
public func assessCursorComposerRecord(_ record: JSONObject, now: Int64) -> TurnAssessment {
    let status = record["status"] as? String ?? "none"
    let generatingIds = record["generatingBubbleIds"] as? [Any] ?? []
    let continuation = (record["isContinuationInProgress"] as? Bool) == true
    let label = cursorProjectLabel(record)

    var lastActivityAt = parseTimestamp(
        firstNonNull(record["conversationCheckpointLastUpdatedAt"], record["lastUpdatedAt"], record["createdAt"]),
        fallbackMs: now
    )

    if status == "generating" || continuation || !generatingIds.isEmpty {
        var reason = "generating"
        if !generatingIds.isEmpty {
            reason = "generating bubbles"
        } else if continuation {
            reason = "continuation in progress"
        } else if (record["unifiedMode"] as? String) == "agent" {
            reason = "agent generating"
        }
        return TurnAssessment(active: true, lastActivityAt: lastActivityAt, reason: reason, label: label)
    }

    let headers = record["fullConversationHeadersOnly"] as? [JSONObject] ?? []

    var openUserTurnAt: Int64?
    var sawCompletedTurnAfterUser = false
    var openTurnTouchesTools = false
    var runningTool = false

    for header in headers {
        let createdAt = parseTimestamp(header["createdAt"], fallbackMs: lastActivityAt)
        if createdAt > lastActivityAt { lastActivityAt = createdAt }

        let grouping = cursorHeaderGrouping(header)
        let toolStatus = (grouping["toolFormerStatus"] as? String)?.lowercased() ?? ""
        let shellStatus = (grouping["shellStatus"] as? String)?.lowercased() ?? ""

        if cursorRunningToolStatuses.contains(toolStatus) || cursorRunningToolStatuses.contains(shellStatus) {
            runningTool = true
            openTurnTouchesTools = true
            sawCompletedTurnAfterUser = false
        }

        // Cursor bubble types: 1 = user, 2 = assistant/tool/thinking
        let headerType = (header["type"] as? NSNumber).map { Int(truncating: $0) }
        if headerType == 1 {
            openUserTurnAt = createdAt
            sawCompletedTurnAfterUser = false
            openTurnTouchesTools = false
            continue
        }

        if openUserTurnAt == nil { continue }

        if finiteNumber(grouping["turnDurationMs"]) != nil {
            // Final assistant bubble for the turn.
            sawCompletedTurnAfterUser = true
            openTurnTouchesTools = false
            continue
        }

        if toolStatus == "completed" || shellStatus == "success" || shellStatus == "completed"
            || shellStatus == "error" || shellStatus == "failed" {
            // Tool finished but the turn may still stream a final reply.
            openTurnTouchesTools = true
            sawCompletedTurnAfterUser = false
            continue
        }

        // Thinking / streaming text / other assistant bubbles before turnDurationMs.
        sawCompletedTurnAfterUser = false
    }

    if runningTool {
        return TurnAssessment(active: true, lastActivityAt: lastActivityAt, reason: "tool_call in progress", label: label)
    }

    if let openUserTurnAt, !sawCompletedTurnAfterUser {
        _ = openUserTurnAt // boundary already folded into lastActivityAt, matching the TS reference.
        let age = now - lastActivityAt
        let grace = openTurnTouchesTools ? toolTurnGraceMs : turnActiveGraceMs
        if age <= grace {
            return TurnAssessment(
                active: true,
                lastActivityAt: lastActivityAt,
                reason: openTurnTouchesTools ? "awaiting model after tool" : "user prompt",
                label: label
            )
        }
        return TurnAssessment(
            active: false,
            lastActivityAt: lastActivityAt,
            reason: openTurnTouchesTools ? "stale tool turn" : "stale user prompt",
            label: label
        )
    }

    let reason: String
    if status == "completed" {
        reason = "completed"
    } else if status == "aborted" {
        reason = "aborted"
    } else {
        reason = "idle"
    }
    return TurnAssessment(active: false, lastActivityAt: lastActivityAt, reason: reason, label: label)
}
