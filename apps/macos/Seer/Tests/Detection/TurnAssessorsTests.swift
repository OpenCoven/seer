import XCTest
@testable import Seer

/// Table-driven parity tests: every case in the shared fixture oracle
/// (`tests/fixtures/agent-detection/expected.json`) is asserted against the
/// Swift turn assessors. TypeScript's `tests/agent-detection-parity.test.mjs`
/// asserts the exact same oracle through
/// `assessDetectionFixture` in `main/services/agent-detection-policy.ts` —
/// this file locates the oracle from `#filePath` rather than copying or
/// restating any expected value, so both languages are proven to agree on
/// the exact same corpus.
final class TurnAssessorsTests: XCTestCase {
    private final class LockedCompilationCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        func increment() {
            lock.lock()
            storage += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    // MARK: - Shared fixture oracle

    private struct FixtureOracle: Decodable {
        let now: String
        let cases: [FixtureCase]
    }

    private struct FixtureCase: Decodable {
        let id: String
        let family: String
        let kind: String
        let format: String?
        let fixtureFile: String
        let identity: String?
        let mtimeMs: String?
        let selector: String?
        let expected: FixtureExpected
    }

    private struct FixtureExpected: Decodable, Equatable {
        let active: Bool
        let source: AgentActivitySource
        let detail: String
        let id: String
    }

    private enum FixtureAssessorError: Error {
        case invalidFixture(String)
        case missingSelector(String)
    }

    /// Walks up from this test file to the repository root and back down to
    /// the shared fixture directory — never a copy of fixture content.
    private func fixturesDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/Detection
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Seer (apps/macos/Seer project root)
            .deletingLastPathComponent() // apps/macos
            .deletingLastPathComponent() // apps
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("tests/fixtures/agent-detection", isDirectory: true)
    }

    private func loadOracle() throws -> FixtureOracle {
        let url = fixturesDirectory().appendingPathComponent("expected.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(FixtureOracle.self, from: data)
    }

    private func readJSONValue(_ fixtureFile: String) throws -> Any {
        let url = fixturesDirectory().appendingPathComponent(fixtureFile)
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Parses line-delimited JSON tolerating corrupt/partial lines — the same
    /// leniency the production session-tail reader applies.
    private func readJSONLEvents(_ fixtureFile: String) throws -> [JSONObject] {
        let url = fixturesDirectory().appendingPathComponent(fixtureFile)
        let text = try String(contentsOf: url, encoding: .utf8)
        var events: [JSONObject] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{") else { continue }
            guard let data = trimmed.data(using: .utf8) else { continue }
            guard let object = (try? JSONSerialization.jsonObject(with: data, options: [])) as? JSONObject else {
                continue
            }
            events.append(object)
        }
        return events
    }

    /// Assesses a single synthetic fixture case using the exact same pure
    /// turn assessors ported to `TurnAssessors.swift`, mirroring
    /// `assessDetectionFixture` in `main/services/agent-detection-policy.ts`.
    private func assessSharedFixture(_ testCase: FixtureCase, now: Int64) throws -> FixtureExpected {
        if testCase.kind == "process" {
            guard let rows = try readJSONValue(testCase.fixtureFile) as? [JSONObject] else {
                throw FixtureAssessorError.invalidFixture(testCase.fixtureFile)
            }
            guard let row = rows.first(where: { ($0["key"] as? String) == testCase.selector }) else {
                throw FixtureAssessorError.missingSelector(testCase.selector ?? "")
            }
            guard
                let family = row["family"] as? String,
                let pidNumber = row["pid"] as? NSNumber,
                let cpuPercent = finiteNumber(row["cpuPercent"])
            else {
                throw FixtureAssessorError.invalidFixture(testCase.fixtureFile)
            }
            let active = cpuPercent >= processOnlyCPUThreshold
            return FixtureExpected(
                active: active,
                source: .process,
                detail: buildFriendlyDetail(projectLabel: nil, processOnly: true),
                id: "\(family):pid:\(pidNumber.intValue)"
            )
        }

        if testCase.format == "cursor" {
            guard
                let data = try readJSONValue(testCase.fixtureFile) as? JSONObject,
                let composerKey = data["composerKey"] as? String,
                let record = asRecord(data["record"])
            else {
                throw FixtureAssessorError.invalidFixture(testCase.fixtureFile)
            }
            let assessment = assessCursorComposerRecord(record, now: now)
            return FixtureExpected(
                active: assessment.active,
                source: .session,
                detail: buildFriendlyDetail(projectLabel: assessment.label, reason: assessment.reason),
                id: "\(testCase.family):\(composerKey)"
            )
        }

        if testCase.format == "generic-mtime" {
            guard let data = try readJSONValue(testCase.fixtureFile) as? JSONObject else {
                throw FixtureAssessorError.invalidFixture(testCase.fixtureFile)
            }
            let selectorKey = testCase.selector ?? "recent"
            guard
                let entry = asRecord(data[selectorKey]),
                let identity = entry["identity"] as? String,
                let mtimeText = entry["mtimeMs"] as? String,
                let mtimeMs = parseISO8601ToMs(mtimeText)
            else {
                throw FixtureAssessorError.invalidFixture(testCase.fixtureFile)
            }
            let assessment = assessGenericMtime(mtimeMs: mtimeMs, now: now)
            let label = friendlySessionLabel(identity)
            return FixtureExpected(
                active: assessment.active,
                source: .session,
                detail: buildFriendlyDetail(projectLabel: label, reason: assessment.reason),
                id: "\(testCase.family):\(identity)"
            )
        }

        // claude / codex / grok session transcripts.
        let events = try readJSONLEvents(testCase.fixtureFile)
        let mtimeMs = testCase.mtimeMs.flatMap(parseISO8601ToMs) ?? 0
        let identity = testCase.identity ?? ""

        let assessment: TurnAssessment
        switch testCase.format {
        case "claude":
            assessment = assessClaudeTurn(events, mtimeMs: mtimeMs, now: now)
        case "codex":
            assessment = assessCodexTurn(events, mtimeMs: mtimeMs, now: now)
        case "grok":
            assessment = assessGrokTurn(events, mtimeMs: mtimeMs, now: now)
        default:
            throw FixtureAssessorError.invalidFixture(testCase.fixtureFile)
        }

        let label = assessment.label ?? friendlySessionLabel(identity)
        return FixtureExpected(
            active: assessment.active,
            source: .session,
            detail: buildFriendlyDetail(projectLabel: label, reason: assessment.reason),
            id: "\(testCase.family):\(identity)"
        )
    }

    // MARK: - Oracle-driven tests

    func testFixtureAssessments() throws {
        let oracle = try loadOracle()
        guard let fixedNow = parseISO8601ToMs(oracle.now) else {
            XCTFail("expected.json 'now' did not parse as ISO 8601")
            return
        }

        let coveredFamilies = Set(oracle.cases.map(\.family))
        let approvedFamilies = Set(AgentFamily.allCases.map(\.rawValue))
        XCTAssertEqual(
            coveredFamilies,
            approvedFamilies,
            "expected.json must cover exactly the ten approved families"
        )

        XCTAssertTrue(
            oracle.cases.contains { $0.family == "aider" && $0.kind == "process" && $0.expected.source == .process },
            "expected.json must prove Aider process-only detection"
        )
        XCTAssertTrue(
            oracle.cases.contains { $0.family == "amp" && $0.kind == "process" && $0.expected.source == .process },
            "expected.json must prove Amp process-only detection"
        )
        XCTAssertTrue(
            oracle.cases.contains { $0.family == "cursor" && $0.kind == "process" && $0.expected.source == .process },
            "expected.json must prove Cursor CLI process-only detection"
        )

        for testCase in oracle.cases {
            let result = try assessSharedFixture(testCase, now: fixedNow)
            XCTAssertEqual(result, testCase.expected, testCase.id)
        }
    }

    // MARK: - Direct unit cases beyond the oracle

    func testHumanizeProjectNameStripsLocalAndHexSuffixes() {
        // "my" is a 2-character word that is already lowercase, so it is left
        // untouched (only words longer than 2 characters are capitalized) —
        // this is a faithful, deliberate port of the TS `titleCaseWords` rule.
        XCTAssertEqual(humanizeProjectName("my-project-local-1pwq7g9n"), "my Project")
        XCTAssertEqual(humanizeProjectName("my-project-a1b2c3"), "my Project")
        XCTAssertEqual(humanizeProjectName("seer-project.name"), "Seer Project Name")
        XCTAssertEqual(humanizeProjectName(""), "")
    }

    func testFriendlyActivityMapsReasonsToLabels() {
        XCTAssertEqual(friendlyActivity(nil, processOnly: true), "Busy")
        XCTAssertEqual(friendlyActivity("tool_use in progress", processOnly: false), "Running tools")
        XCTAssertEqual(friendlyActivity("awaiting model after tool", processOnly: false), "Thinking")
        XCTAssertEqual(friendlyActivity("agent_reasoning", processOnly: false), "Thinking")
        XCTAssertEqual(friendlyActivity("agent_message", processOnly: false), "Writing")
        XCTAssertEqual(friendlyActivity("user prompt", processOnly: false), "Started")
        XCTAssertEqual(friendlyActivity("generating bubbles", processOnly: false), "Writing")
        XCTAssertEqual(friendlyActivity("recent session write", processOnly: false), "Active")
        XCTAssertEqual(friendlyActivity("stale session write", processOnly: false), "Wrapping up")
        XCTAssertEqual(friendlyActivity("end_turn", processOnly: false), "Working")
        XCTAssertEqual(friendlyActivity(nil, processOnly: false), "Working")
    }

    func testParseTimestampHandlesSecondsMillisecondsAndFallback() {
        // Seconds-based epoch (below the 1e12 cutoff) is scaled to ms.
        XCTAssertEqual(parseTimestamp(1_700_000_000, fallbackMs: -1), 1_700_000_000_000)
        // Already-ms epoch (above the cutoff) passes through unchanged.
        XCTAssertEqual(parseTimestamp(1_700_000_000_000, fallbackMs: -1), 1_700_000_000_000)
        // ISO 8601 strings parse to the same Unix ms Date.parse would produce.
        XCTAssertEqual(parseTimestamp("2026-08-10T12:00:00.000Z", fallbackMs: -1), 1_786_363_200_000)
        // A JSON boolean must not be treated as a numeric timestamp.
        XCTAssertEqual(parseTimestamp(true, fallbackMs: 42), 42)
        // Unparseable strings and missing values fall back.
        XCTAssertEqual(parseTimestamp("not-a-date", fallbackMs: 7), 7)
        XCTAssertEqual(parseTimestamp(nil, fallbackMs: 7), 7)
    }

    func testGrokProjectLabelDecodesPercentEncodedCwd() {
        let path = "/home/user/.grok/sessions/%2Fhome%2Fuser%2Fmy-app/session-1/events.jsonl"
        // "my" is a 2-character lowercase word left untouched by titleCaseWords.
        XCTAssertEqual(grokProjectLabel(path), "my App")
        XCTAssertEqual(grokProjectLabel("events.jsonl"), "")
    }

    func testAssessGenericMtimeIsExactlyAtTheTwentySecondBoundary() {
        let now: Int64 = 1_786_449_620_000
        let atBoundary = assessGenericMtime(mtimeMs: now - genericMtimeWindowMs, now: now)
        XCTAssertTrue(atBoundary.active, "age == 20s must still be active (inclusive boundary)")

        let pastBoundary = assessGenericMtime(mtimeMs: now - genericMtimeWindowMs - 1, now: now)
        XCTAssertFalse(pastBoundary.active, "age == 20s + 1ms must be stale")
    }

    func testRecencyHelperEnforcesGraceFutureSkewAndOverflowBoundaries() {
        let now: Int64 = 1_786_449_620_000
        let cases: [(name: String, timestamp: Int64, grace: Int64, expected: Bool)] = [
            ("grace start", now - turnActiveGraceMs, turnActiveGraceMs, true),
            ("past grace", now - turnActiveGraceMs - 1, turnActiveGraceMs, false),
            ("future skew boundary", now + timestampFutureSkewMs, turnActiveGraceMs, true),
            ("past future skew", now + timestampFutureSkewMs + 1, turnActiveGraceMs, false),
            ("extreme future", Int64.max, turnActiveGraceMs, false),
            ("extreme past", Int64.min, turnActiveGraceMs, false),
            ("overflow future", Int64.max, Int64.min, false),
            ("overflow past", Int64.min, Int64.max, false),
        ]

        for testCase in cases {
            XCTAssertEqual(
                isRecentTimestamp(testCase.timestamp, now: now, within: testCase.grace),
                testCase.expected,
                testCase.name
            )
        }
    }

    func testEveryAssessorFamilyRejectsExtremeFutureButAcceptsBoundedClockSkew() {
        let now: Int64 = 1_786_449_620_000
        let assessors: [(String, (Int64) -> TurnAssessment)] = [
            ("claude", { timestamp in
                assessClaudeTurn(
                    [["type": "assistant", "timestamp": timestamp, "message": ["stop_reason": "tool_use"]]],
                    mtimeMs: now,
                    now: now
                )
            }),
            ("codex", { timestamp in
                assessCodexTurn(
                    [["timestamp": timestamp, "type": "event_msg", "payload": ["type": "task_started"]]],
                    mtimeMs: now,
                    now: now
                )
            }),
            ("grok", { timestamp in
                assessGrokTurn([["ts": timestamp, "type": "turn_started"]], mtimeMs: now, now: now)
            }),
            ("generic mtime", { timestamp in
                assessGenericMtime(mtimeMs: timestamp, now: now)
            }),
            ("cursor", { timestamp in
                assessCursorComposerRecord(
                    ["status": "generating", "lastUpdatedAt": timestamp, "fullConversationHeadersOnly": []],
                    now: now
                )
            }),
        ]

        for (name, assess) in assessors {
            XCTAssertTrue(assess(now + timestampFutureSkewMs).active, "\(name) must tolerate the documented skew")
            XCTAssertFalse(assess(Int64.max).active, "\(name) must reject extreme future evidence")
        }
    }

    func testCodexAndGrokQuietTailFallbacksRejectExtremeFutureMtimeButAllowBoundedSkew() {
        let now: Int64 = 1_786_449_620_000
        for (name, assess) in [
            ("codex", { (mtime: Int64) in assessCodexTurn([], mtimeMs: mtime, now: now) }),
            ("grok", { (mtime: Int64) in assessGrokTurn([], mtimeMs: mtime, now: now) }),
        ] {
            XCTAssertTrue(assess(now + timestampFutureSkewMs).active, "\(name) fallback must tolerate bounded skew")
            XCTAssertFalse(assess(Int64.max).active, "\(name) fallback must reject extreme future mtime")
        }
    }

    // MARK: - Timestamp overflow hardening (Finding 1)

    /// A finite JSON number far above `Int64` range (`1e300`) must saturate
    /// to `Int64.max` rather than trapping in `Int64(doubleValue)`. `1e300 >
    /// 1e12`, so this exercises the "already milliseconds" branch directly
    /// (no multiplication involved).
    func testParseTimestampSaturatesAboveInt64RangeInsteadOfTrapping() {
        XCTAssertEqual(parseTimestamp(1e300, fallbackMs: -1), Int64.max)
    }

    /// A finite JSON number far below negative `Int64` range (`-1e300`) must
    /// saturate to `Int64.min`. `-1e300` is not `> 1e12`, so this exercises
    /// the "seconds → ms" branch, i.e. a `Double` multiplication by 1000
    /// (`-1e300 * 1000 == -1e303`) followed by a saturating conversion.
    func testParseTimestampSaturatesBelowInt64RangeInsteadOfTrapping() {
        XCTAssertEqual(parseTimestamp(-1e300, fallbackMs: -1), Int64.min)
    }

    /// Values whose magnitude alone wouldn't overflow `Int64`, but which
    /// cross the boundary only *after* the `* 1000` seconds→ms multiplication,
    /// must also saturate instead of trapping. `-1e16` is well within
    /// `Double`/`Int64` range on its own, but `-1e16 * 1000 == -1e19`, which
    /// exceeds `Int64.min` (~`-9.223e18`).
    func testParseTimestampSaturatesOnMultiplicationBoundaryOverflow() {
        XCTAssertEqual(parseTimestamp(-1e16, fallbackMs: -1), Int64.min)
    }

    /// A value just inside the seconds→ms multiplication range must convert
    /// exactly, proving the saturation logic doesn't clamp values that
    /// legitimately fit — only genuine out-of-range magnitudes.
    func testParseTimestampDoesNotOversaturateInRangeMultiplication() {
        XCTAssertEqual(parseTimestamp(-9.2e12, fallbackMs: -1), Int64(-9.2e12 * 1000))
    }

    /// `finiteNumber`/`parseTimestamp` must reject non-finite `NSNumber`
    /// values (`+inf`, `-inf`, `NaN`) called directly — mirroring TS
    /// `Number.isFinite` — and fall back rather than trapping on the
    /// downstream `Int64` conversion.
    func testParseTimestampFallsBackOnNonfiniteNSNumberCalledDirectly() {
        XCTAssertEqual(parseTimestamp(NSNumber(value: Double.infinity), fallbackMs: 42), 42)
        XCTAssertEqual(parseTimestamp(NSNumber(value: -Double.infinity), fallbackMs: 42), 42)
        XCTAssertEqual(parseTimestamp(NSNumber(value: Double.nan), fallbackMs: 42), 42)
    }

    /// End-to-end: syntactically valid JSON containing `1e300` must parse via
    /// `JSONSerialization`, flow through `assessClaudeTurn` without trapping,
    /// and produce a bounded `lastActivityAt`. A future-huge timestamp must
    /// saturate to `Int64.max` and be rejected as implausibly future-dated.
    func testAssessClaudeTurnSurvivesHugeFutureTimestampJSON() throws {
        let json = #"""
        [{"type":"assistant","timestamp":1e300,"message":{"stop_reason":"tool_use"}}]
        """#
        let events = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) as? [JSONObject]
        )
        let now: Int64 = 1_786_449_620_000
        let assessment = assessClaudeTurn(events, mtimeMs: now, now: now)
        XCTAssertEqual(assessment.lastActivityAt, Int64.max)
        XCTAssertFalse(assessment.active, "a huge future timestamp must be rejected, not active forever")
    }

    /// The past-huge mirror: `-1e300` must saturate to `Int64.min`, and the
    /// resulting astronomically large age must classify as stale rather than
    /// trapping the `now - timestamp` subtraction.
    func testAssessClaudeTurnSurvivesHugeAncientTimestampJSON() throws {
        let json = #"""
        [{"type":"assistant","timestamp":-1e300,"message":{"stop_reason":"tool_use"}}]
        """#
        let events = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) as? [JSONObject]
        )
        let now: Int64 = 1_786_449_620_000
        let assessment = assessClaudeTurn(events, mtimeMs: now, now: now)
        XCTAssertEqual(assessment.lastActivityAt, Int64.min)
        XCTAssertFalse(assessment.active, "a huge ancient timestamp must saturate to stale, not trap")
    }

    /// Same JSON-callable trap coverage for the Codex assessor: a huge future
    /// `timestamp` in an `event_msg`/`task_started` record must not trap, and
    /// must be rejected as implausibly future-dated.
    func testAssessCodexTurnSurvivesHugeFutureTimestampJSON() throws {
        let json = #"""
        [{"timestamp":1e300,"type":"event_msg","payload":{"type":"task_started","cwd":"/tmp/x"}}]
        """#
        let events = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) as? [JSONObject]
        )
        let now: Int64 = 1_786_449_620_000
        let assessment = assessCodexTurn(events, mtimeMs: now, now: now)
        XCTAssertEqual(assessment.lastActivityAt, Int64.max)
        XCTAssertFalse(assessment.active)
    }

    /// Same JSON-callable trap coverage for the Grok assessor. Grok tracks
    /// `lastActivityAt` via a running max (`if at > lastActivityAt { … }`),
    /// so a huge-ancient timestamp (saturating to `Int64.min`) can never win
    /// that comparison against a real anchor event — this is the exact same
    /// (crash-free) outcome the TS reference produces for identical input,
    /// not a Swift-only quirk: the huge-ancient event is simply ignored by
    /// the max-tracking logic, and the assessment reflects the real anchor
    /// event instead of trapping or corrupting `lastActivityAt`.
    func testAssessGrokTurnSurvivesHugeAncientTimestampJSON() throws {
        let json = #"""
        [
          {"ts": 1786449520000, "type": "turn_started"},
          {"ts": -1e300, "type": "phase_changed", "phase": "streaming_text"}
        ]
        """#
        let events = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) as? [JSONObject]
        )
        let now: Int64 = 1_786_449_620_000
        let assessment = assessGrokTurn(events, mtimeMs: now, now: now)
        XCTAssertEqual(assessment.lastActivityAt, 1_786_449_520_000)
        XCTAssertTrue(assessment.active)
        XCTAssertEqual(assessment.reason, "user prompt")
    }

    /// The generic-mtime assessor takes a bare `Int64` `mtimeMs`, not a
    /// parsed JSON value, but its `now - mtimeMs` age subtraction must still
    /// be overflow-safe against an already-saturated extreme timestamp
    /// (e.g. one that flowed in from `parseTimestamp` upstream).
    func testAssessGenericMtimeSurvivesSaturatedExtremeTimestamps() {
        let now: Int64 = 1_786_449_620_000
        let future = assessGenericMtime(mtimeMs: Int64.max, now: now)
        XCTAssertFalse(future.active)
        let ancient = assessGenericMtime(mtimeMs: Int64.min, now: now)
        XCTAssertFalse(ancient.active)
    }

    /// The Cursor composer assessor reads timestamps through `parseTimestamp`
    /// too (`conversationCheckpointLastUpdatedAt`/`lastUpdatedAt`/`createdAt`),
    /// so it must survive the same huge-JSON-number trap.
    func testAssessCursorComposerRecordSurvivesHugeFutureTimestampJSON() throws {
        let json = #"""
        {"status":"none","lastUpdatedAt":1e300,"fullConversationHeadersOnly":[]}
        """#
        let record = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) as? JSONObject
        )
        let now: Int64 = 1_786_449_620_000
        let assessment = assessCursorComposerRecord(record, now: now)
        XCTAssertEqual(assessment.lastActivityAt, Int64.max)
        XCTAssertFalse(assessment.active)
    }

    /// Direct boundary tests for the saturating subtraction helper backing
    /// every `age = now - timestamp` computation: overflow in either
    /// direction must saturate, not trap, and in-range subtraction must be
    /// exact.
    func testSaturatingSubtractHandlesOverflowInBothDirections() {
        XCTAssertEqual(saturatingSubtract(10, 3), 7)
        XCTAssertEqual(saturatingSubtract(0, Int64.min), Int64.max, "0 - Int64.min overflows positive")
        XCTAssertEqual(saturatingSubtract(Int64.min, Int64.max), Int64.min, "Int64.min - Int64.max overflows negative")
        XCTAssertEqual(saturatingSubtract(Int64.max, Int64.max), 0)
    }

    /// Direct boundary tests for the saturating `Double -> Int64` conversion
    /// backing `parseTimestamp`.
    func testSaturatingInt64ClampsNonfiniteAndOutOfRangeValues() {
        XCTAssertEqual(saturatingInt64(Double.infinity), Int64.max)
        XCTAssertEqual(saturatingInt64(-Double.infinity), Int64.min)
        XCTAssertEqual(saturatingInt64(Double.nan), Int64.min, "NaN has no sign; saturating to a bound must not trap")
        XCTAssertEqual(saturatingInt64(1e300), Int64.max)
        XCTAssertEqual(saturatingInt64(-1e300), Int64.min)
        XCTAssertEqual(saturatingInt64(42.0), 42)
    }

    // MARK: - Process matcher case-sensitivity (Finding 2)

    private struct MatcherFixtureOracle: Decodable {
        let matcherCases: [MatcherFixtureCase]
    }

    private struct MatcherFixtureCase: Decodable {
        let id: String
        let kind: String
        let family: String?
        let patternIndex: Int?
        let command: String
        let expectedFamily: String??
        let expectedMatch: Bool?
    }

    private func loadMatcherOracle() throws -> MatcherFixtureOracle {
        let url = fixturesDirectory().appendingPathComponent("expected.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(MatcherFixtureOracle.self, from: data)
    }

    /// Cross-language parity: every `matcherCases` row is asserted here and
    /// in `tests/agent-detection-parity.test.mjs` against the exact same
    /// `command` / `patternIndex` values, proving Swift's `matchAgentKind`
    /// (whole-family) and per-pattern case-sensitivity flags agree with the
    /// TS `RegExp` reference, including the five intentionally
    /// case-sensitive scoped-package patterns TS never applies `/i` to.
    func testProcessMatcherOracle() throws {
        let oracle = try loadMatcherOracle()
        XCTAssertFalse(oracle.matcherCases.isEmpty)

        for testCase in oracle.matcherCases {
            switch testCase.kind {
            case "family":
                let matched = matchAgentKind(command: testCase.command)
                let expected = (testCase.expectedFamily ?? nil).flatMap { $0 }
                XCTAssertEqual(matched?.id.rawValue, expected, testCase.id)

            case "pattern":
                guard
                    let familyRaw = testCase.family,
                    let family = AgentFamily(rawValue: familyRaw),
                    let patternIndex = testCase.patternIndex,
                    let expectedMatch = testCase.expectedMatch,
                    let kind = AGENT_KINDS.first(where: { $0.id == family })
                else {
                    XCTFail("malformed pattern matcher case \(testCase.id)")
                    continue
                }
                XCTAssertTrue(patternIndex >= 0 && patternIndex < kind.processMatchers.count, testCase.id)
                let matcher = kind.processMatchers[patternIndex]
                XCTAssertEqual(matcher.matches(testCase.command), expectedMatch, testCase.id)

            default:
                XCTFail("unknown matcherCases kind \(testCase.kind)")
            }
        }
    }

    func testProcessDefinitionsCompileEachPatternOnceOutsideMatchingHotLoop() {
        let counter = LockedCompilationCounter()
        let definitions = makeAgentKinds(
            regexCompiler: ProcessRegexCompiler(onCompilation: counter.increment)
        )
        let patternCount = definitions.reduce(0) { $0 + $1.processMatchers.count }
        XCTAssertGreaterThan(patternCount, 0)
        XCTAssertEqual(patternCount, AGENT_KINDS.reduce(0) { $0 + $1.processMatchers.count })
        XCTAssertEqual(counter.value, patternCount)

        let commands = [
            "/opt/homebrew/bin/claude",
            "npx @openai/codex",
            "/Users/example/.grok/downloads/grok-1.2.3-macos-arm64",
            "cursor-agent --agent",
            "definitely-not-an-agent",
        ]
        for index in 0..<10_000 {
            _ = matchAgentKind(command: commands[index % commands.count], kinds: definitions)
        }

        XCTAssertEqual(
            counter.value,
            patternCount,
            "matching thousands of processes must reuse the definitions' precompiled regexes"
        )
    }

    /// Structural guard: exactly the five scoped-package patterns
    /// (`@anthropic-ai/claude-code`, `@openai/codex`, `@google/gemini-cli`,
    /// `@sourcegraph/amp`, `@continuedev/cli`) are compiled case-sensitively;
    /// every other pattern stays case-insensitive, mirroring the `/i` flag
    /// (or its absence) on each `RegExp` literal in the TS policy exactly.
    func testExactlyFiveScopedPackagePatternsAreCaseSensitive() {
        let caseSensitivePatterns = AGENT_KINDS.flatMap { kind in
            kind.processMatchers.filter { !$0.caseInsensitive }.map(\.pattern)
        }
        XCTAssertEqual(caseSensitivePatterns.count, 5)
        XCTAssertEqual(Set(caseSensitivePatterns), [
            #"@anthropic-ai/claude-code"#,
            #"@openai/codex"#,
            #"@google/gemini-cli"#,
            #"@sourcegraph/amp"#,
            #"@continuedev/cli"#,
        ])
    }

    // MARK: - Cursor composer header `type` strict-equality hardening (Finding 2)

    /// Builds a Cursor composer record with a single conversation header
    /// whose `type` field is `headerType` and a recent `createdAt`. Status
    /// is `"completed"` (not `"generating"`) so the record only becomes
    /// `active` if the header loop itself recognizes `headerType` as a
    /// user-turn opener (`type == 1`) — an idle `"completed"`/`false` result
    /// proves the header was correctly rejected.
    private func assessCursorHeaderType(_ headerType: Any, now: Int64) -> TurnAssessment {
        let record: JSONObject = [
            "status": "completed",
            "lastUpdatedAt": now - 1_000,
            "fullConversationHeadersOnly": [
                ["type": headerType, "createdAt": now - 1_000] as JSONObject,
            ],
        ]
        return assessCursorComposerRecord(record, now: now)
    }

    /// TS uses strict equality (`header.type === 1`), which a JSON boolean
    /// can never satisfy (`true === 1` is `false` in JS). `JSONSerialization`
    /// represents JSON `true` as an `NSNumber` indistinguishable from `1` by
    /// naive `NSNumber` truncation, so a header of `type: true` must NOT be
    /// treated as a user-turn opener — the turn stays idle/"completed", not
    /// an open active user prompt.
    func testAssessCursorComposerRecordRejectsBooleanHeaderType() {
        let now: Int64 = 1_786_449_620_000
        let assessment = assessCursorHeaderType(true, now: now)
        XCTAssertFalse(assessment.active, "a JSON boolean `type` must never open a user turn")
        XCTAssertEqual(assessment.reason, "completed")
    }

    /// `1.0` is the exact same JS/JSON number as `1` (`1.0 === 1` is `true`
    /// in JS; IEEE-754 doubles don't distinguish integral floats), so this
    /// must still open a user turn — proving the fix isn't over-broad.
    func testAssessCursorComposerRecordAcceptsNumericOneEquivalentToInteger() {
        let now: Int64 = 1_786_449_620_000
        let assessment = assessCursorHeaderType(1.0, now: now)
        XCTAssertTrue(assessment.active, "1.0 == 1 numerically and must open a user turn, matching TS `=== 1`")
        XCTAssertEqual(assessment.reason, "user prompt")
    }

    /// `1.5 !== 1` under strict equality; a non-integral numeric `type` must
    /// not be treated as the user-bubble marker.
    func testAssessCursorComposerRecordRejectsNonIntegralHeaderType() {
        let now: Int64 = 1_786_449_620_000
        let assessment = assessCursorHeaderType(1.5, now: now)
        XCTAssertFalse(assessment.active, "1.5 is not strictly === 1 and must never open a user turn")
        XCTAssertEqual(assessment.reason, "completed")
    }

    /// `"1" !== 1` under strict equality (no numeric coercion); a JSON
    /// string `type` must never be treated as the user-bubble marker even
    /// if the string carries a numerically equivalent value.
    func testAssessCursorComposerRecordRejectsStringHeaderType() {
        let now: Int64 = 1_786_449_620_000
        let assessment = assessCursorHeaderType("1", now: now)
        XCTAssertFalse(assessment.active, "a JSON string \"1\" must never open a user turn")
        XCTAssertEqual(assessment.reason, "completed")
    }

    /// Normal fixture behavior must be unaffected: an integer JSON `type: 1`
    /// header still opens a user turn exactly as before the hardening.
    func testAssessCursorComposerRecordStillAcceptsIntegerHeaderType() {
        let now: Int64 = 1_786_449_620_000
        let assessment = assessCursorHeaderType(1, now: now)
        XCTAssertTrue(assessment.active, "a plain integer 1 must still open a user turn")
        XCTAssertEqual(assessment.reason, "user prompt")
    }

    func testAssessCodexTurnDistinguishesApprovalFromCompletion() {
        let cwdPayload: JSONObject = ["cwd": "/tmp/seer-fixtures/codex-boundary-project"]
        let started: JSONObject = [
            "timestamp": "2026-08-10T12:00:00.000Z",
            "type": "event_msg",
            "payload": ["type": "task_started"].merging(cwdPayload) { _, new in new },
        ]
        let approval: JSONObject = [
            "timestamp": "2026-08-10T12:00:05.000Z",
            "type": "event_msg",
            "payload": ["type": "exec_approval_request"],
        ]
        let now = parseISO8601ToMs("2026-08-10T12:00:06.000Z")!

        let assessment = assessCodexTurn([started, approval], mtimeMs: now, now: now)
        XCTAssertFalse(assessment.active)
        XCTAssertEqual(assessment.reason, "waiting for approval")
        XCTAssertEqual(assessment.label, "Codex Boundary Project")
    }
}
