import Foundation

/// Exactly the ten approved agent families ported from `AGENT_KINDS` in
/// `main/services/agent-detection-policy.ts`. The raw value is the stable
/// family id used to prefix every `ActiveAgent.id` (`"<family>:<identity>"`),
/// matching the TypeScript `AgentKind.id` string exactly — including
/// `"claude-code"` and `"continue"`, which are not valid Swift identifiers as
/// case names, hence the differing case names with explicit raw values.
public enum AgentFamily: String, Codable, Equatable, Sendable, CaseIterable {
    case claudeCode = "claude-code"
    case codex
    case grok
    case gemini
    case aider
    case opencode
    case goose
    case amp
    case cursor
    case continueAgent = "continue"
}

/// Mirrors `AgentKind["sessionFormat"]` in the TypeScript policy: how to
/// interpret a family's on-disk session files, if any.
public enum SessionFormat: String, Equatable, Sendable {
    case claude
    case codex
    case grok
    case genericMtime = "generic-mtime"
    case cursor
    case none
}

/// Compilation seam used to characterize definition initialization without
/// adding timing assertions to the process-matching performance test.
struct ProcessRegexCompiler: Sendable {
    private let onCompilation: @Sendable () -> Void

    init(onCompilation: @escaping @Sendable () -> Void = {}) {
        self.onCompilation = onCompilation
    }

    fileprivate func compile(
        pattern: String,
        options: NSRegularExpression.Options
    ) -> SendableProcessRegex {
        onCompilation()
        return SendableProcessRegex(pattern: pattern, options: options)
    }
}

private final class SendableProcessRegex: @unchecked Sendable {
    private let expression: NSRegularExpression?

    init(pattern: String, options: NSRegularExpression.Options) {
        expression = try? NSRegularExpression(pattern: pattern, options: options)
    }

    func matches(_ command: String) -> Bool {
        guard let expression else { return false }
        let fullRange = NSRange(command.startIndex..<command.endIndex, in: command)
        return expression.firstMatch(in: command, options: [], range: fullRange) != nil
    }
}

/// A single process-command matcher: an ICU-compatible regex pattern plus
/// whether it should compile case-insensitively. Mirrors one `RegExp`
/// literal from `processMatchers` in the TS policy exactly, including its
/// flags — most TS patterns carry `/i`, but five scoped-npm-package
/// patterns (`@anthropic-ai/claude-code`, `@openai/codex`,
/// `@google/gemini-cli`, `@sourcegraph/amp`, `@continuedev/cli`) are
/// intentionally left case-sensitive in the TS source. A typed carrier (not
/// a string convention, e.g. an inline `(?i)` prefix) keeps that flag
/// explicit and out-of-band from the pattern text itself.
public struct ProcessMatcher: Equatable, Sendable {
    public let pattern: String
    public let caseInsensitive: Bool
    private let compiledRegex: SendableProcessRegex

    public init(_ pattern: String, caseInsensitive: Bool = true) {
        self.init(pattern, caseInsensitive: caseInsensitive, regexCompiler: ProcessRegexCompiler())
    }

    init(
        _ pattern: String,
        caseInsensitive: Bool = true,
        regexCompiler: ProcessRegexCompiler
    ) {
        self.pattern = pattern
        self.caseInsensitive = caseInsensitive
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        compiledRegex = regexCompiler.compile(pattern: pattern, options: options)
    }

    public static func == (lhs: ProcessMatcher, rhs: ProcessMatcher) -> Bool {
        lhs.pattern == rhs.pattern && lhs.caseInsensitive == rhs.caseInsensitive
    }

    func matches(_ command: String) -> Bool {
        compiledRegex.matches(command)
    }
}

/// Mirrors `AgentKind` in `main/services/agent-detection-policy.ts`.
/// Process regexes are compiled once when each definition is initialized and
/// held by an immutable, `Sendable` wrapper for reuse across scans.
public struct AgentKind: Equatable, Sendable {
    public let id: AgentFamily
    public let name: String
    public let processMatchers: [ProcessMatcher]
    public let sessionRoots: [String]
    public let sessionExtensions: [String]
    /// Only consider session files with these exact names (e.g. Grok's events.jsonl).
    public let sessionFileNames: [String]?
    public let sessionFormat: SessionFormat
    /// If true, never treat bare process CPU as active work.
    public let requireSessionTurn: Bool
    /// Allow high-CPU process fallback even when a session format exists (e.g. Cursor CLI).
    public let allowProcessFallback: Bool

    public init(
        id: AgentFamily,
        name: String,
        processMatchers: [ProcessMatcher],
        sessionRoots: [String],
        sessionExtensions: [String],
        sessionFileNames: [String]? = nil,
        sessionFormat: SessionFormat,
        requireSessionTurn: Bool = false,
        allowProcessFallback: Bool = false
    ) {
        self.id = id
        self.name = name
        self.processMatchers = processMatchers
        self.sessionRoots = sessionRoots
        self.sessionExtensions = sessionExtensions
        self.sessionFileNames = sessionFileNames
        self.sessionFormat = sessionFormat
        self.requireSessionTurn = requireSessionTurn
        self.allowProcessFallback = allowProcessFallback
    }
}

/// Exactly the ten approved agent families, faithfully ported from
/// `AGENT_KINDS` in `main/services/agent-detection-policy.ts`. Process
/// matchers, session roots/extensions/formats, and fallback flags are
/// preserved verbatim from the TypeScript source.
public let AGENT_KINDS: [AgentKind] = makeAgentKinds()

func makeAgentKinds(regexCompiler: ProcessRegexCompiler = ProcessRegexCompiler()) -> [AgentKind] {
    func matcher(_ pattern: String, caseInsensitive: Bool = true) -> ProcessMatcher {
        ProcessMatcher(pattern, caseInsensitive: caseInsensitive, regexCompiler: regexCompiler)
    }

    return [
    AgentKind(
        id: .claudeCode,
        name: "Claude Code",
        processMatchers: [
            matcher(#"(^|[/\s])claude(\s|$)"#),
            matcher(#"@anthropic-ai/claude-code"#, caseInsensitive: false),
            matcher(#"claude[-_]code"#),
        ],
        sessionRoots: [".claude/projects"],
        sessionExtensions: [".jsonl"],
        sessionFormat: .claude,
        requireSessionTurn: true
    ),
    AgentKind(
        id: .codex,
        name: "Codex",
        processMatchers: [
            matcher(#"(^|[/\s])codex(\s|$)"#),
            matcher(#"@openai/codex"#, caseInsensitive: false),
        ],
        sessionRoots: [".codex/sessions"],
        sessionExtensions: [".jsonl"],
        sessionFormat: .codex,
        requireSessionTurn: true
    ),
    AgentKind(
        id: .grok,
        name: "Grok",
        // The launcher lives in ~/.grok/bin; the real binary is ~/.grok/downloads/grok-<ver>-macos-*.
        processMatchers: [
            matcher(#"(^|[/\s])grok(\s|$)"#),
            matcher(#"\.grok/(?:bin|downloads)/"#),
            matcher(#"grok-\d+\.\d+\.\d+-macos"#),
        ],
        sessionRoots: [".grok/sessions"],
        sessionExtensions: [".jsonl"],
        // Sessions also hold chat_history/updates/rewind_points — only events.jsonl has turn state.
        sessionFileNames: ["events.jsonl"],
        sessionFormat: .grok,
        requireSessionTurn: true
    ),
    AgentKind(
        id: .gemini,
        name: "Gemini CLI",
        processMatchers: [
            matcher(#"(^|[/\s])gemini(\s|$)"#),
            matcher(#"@google/gemini-cli"#, caseInsensitive: false),
        ],
        sessionRoots: [".gemini"],
        sessionExtensions: [".jsonl", ".json"],
        sessionFormat: .genericMtime
    ),
    AgentKind(
        id: .aider,
        name: "Aider",
        processMatchers: [matcher(#"(^|[/\s])aider(\s|$)"#)],
        sessionRoots: [],
        sessionExtensions: [],
        sessionFormat: .none
    ),
    AgentKind(
        id: .opencode,
        name: "OpenCode",
        processMatchers: [matcher(#"(^|[/\s])opencode(\s|$)"#)],
        sessionRoots: [".local/share/opencode", ".config/opencode"],
        sessionExtensions: [".jsonl", ".json"],
        sessionFormat: .genericMtime
    ),
    AgentKind(
        id: .goose,
        name: "Goose",
        processMatchers: [matcher(#"(^|[/\s])goose(\s|$)"#)],
        sessionRoots: [".config/goose"],
        sessionExtensions: [".jsonl", ".json"],
        sessionFormat: .genericMtime
    ),
    AgentKind(
        id: .amp,
        name: "Amp",
        processMatchers: [
            matcher(#"(^|[/\s])amp(\s|$)"#),
            matcher(#"@sourcegraph/amp"#, caseInsensitive: false),
        ],
        sessionRoots: [],
        sessionExtensions: [],
        sessionFormat: .none
    ),
    AgentKind(
        id: .cursor,
        name: "Cursor",
        // IDE agent is detected via composer state; process matchers cover the CLI only.
        // Do not match bare Cursor.app — it stays open while idle.
        processMatchers: [
            matcher(#"(^|[/\s])cursor-agent(\s|$)"#),
            matcher(#"cursor-agent-svc"#),
            matcher(#"cursor(?:-agent)?(?:\.js)?\s+--agent\b"#),
        ],
        sessionRoots: [],
        sessionExtensions: [],
        sessionFormat: .cursor,
        allowProcessFallback: true
    ),
    AgentKind(
        id: .continueAgent,
        name: "Continue",
        processMatchers: [
            matcher(#"continue-cli"#),
            matcher(#"@continuedev/cli"#, caseInsensitive: false),
        ],
        sessionRoots: [".continue/sessions"],
        sessionExtensions: [".jsonl", ".json"],
        sessionFormat: .genericMtime
    ),
    ]
}

/// Uses each candidate's precompiled process matchers and returns the first
/// `AgentKind` whose patterns match `command`, mirroring
/// `matchAgentKind` in the TypeScript policy: patterns are tried in
/// declaration order (first match wins) and each pattern's case-sensitivity
/// is applied exactly as declared — most are `/i` (case-insensitive), but
/// the five scoped-package patterns above are intentionally not, matching
/// non-global JS `RegExp.test` semantics (a plain "does this match
/// anywhere" check, no lastIndex state).
public func matchAgentKind(command: String) -> AgentKind? {
    matchAgentKind(command: command, kinds: AGENT_KINDS)
}

func matchAgentKind(command: String, kinds: [AgentKind]) -> AgentKind? {
    for kind in kinds {
        for matcher in kind.processMatchers {
            if matcher.matches(command) {
                return kind
            }
        }
    }
    return nil
}
