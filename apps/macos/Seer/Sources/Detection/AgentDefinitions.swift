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

    public init(_ pattern: String, caseInsensitive: Bool = true) {
        self.pattern = pattern
        self.caseInsensitive = caseInsensitive
    }
}

/// Mirrors `AgentKind` in `main/services/agent-detection-policy.ts`.
/// Regex patterns are kept as raw ICU-compatible pattern strings (not
/// precompiled `NSRegularExpression`s) so this value stays a plain,
/// unconditionally `Sendable` value type; `matchAgentKind` compiles them
/// on demand.
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
public let AGENT_KINDS: [AgentKind] = [
    AgentKind(
        id: .claudeCode,
        name: "Claude Code",
        processMatchers: [
            ProcessMatcher(#"(^|[/\s])claude(\s|$)"#),
            ProcessMatcher(#"@anthropic-ai/claude-code"#, caseInsensitive: false),
            ProcessMatcher(#"claude[-_]code"#),
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
            ProcessMatcher(#"(^|[/\s])codex(\s|$)"#),
            ProcessMatcher(#"@openai/codex"#, caseInsensitive: false),
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
            ProcessMatcher(#"(^|[/\s])grok(\s|$)"#),
            ProcessMatcher(#"\.grok/(?:bin|downloads)/"#),
            ProcessMatcher(#"grok-\d+\.\d+\.\d+-macos"#),
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
            ProcessMatcher(#"(^|[/\s])gemini(\s|$)"#),
            ProcessMatcher(#"@google/gemini-cli"#, caseInsensitive: false),
        ],
        sessionRoots: [".gemini"],
        sessionExtensions: [".jsonl", ".json"],
        sessionFormat: .genericMtime
    ),
    AgentKind(
        id: .aider,
        name: "Aider",
        processMatchers: [ProcessMatcher(#"(^|[/\s])aider(\s|$)"#)],
        sessionRoots: [],
        sessionExtensions: [],
        sessionFormat: .none
    ),
    AgentKind(
        id: .opencode,
        name: "OpenCode",
        processMatchers: [ProcessMatcher(#"(^|[/\s])opencode(\s|$)"#)],
        sessionRoots: [".local/share/opencode", ".config/opencode"],
        sessionExtensions: [".jsonl", ".json"],
        sessionFormat: .genericMtime
    ),
    AgentKind(
        id: .goose,
        name: "Goose",
        processMatchers: [ProcessMatcher(#"(^|[/\s])goose(\s|$)"#)],
        sessionRoots: [".config/goose"],
        sessionExtensions: [".jsonl", ".json"],
        sessionFormat: .genericMtime
    ),
    AgentKind(
        id: .amp,
        name: "Amp",
        processMatchers: [
            ProcessMatcher(#"(^|[/\s])amp(\s|$)"#),
            ProcessMatcher(#"@sourcegraph/amp"#, caseInsensitive: false),
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
            ProcessMatcher(#"(^|[/\s])cursor-agent(\s|$)"#),
            ProcessMatcher(#"cursor-agent-svc"#),
            ProcessMatcher(#"cursor(?:-agent)?(?:\.js)?\s+--agent\b"#),
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
            ProcessMatcher(#"continue-cli"#),
            ProcessMatcher(#"@continuedev/cli"#, caseInsensitive: false),
        ],
        sessionRoots: [".continue/sessions"],
        sessionExtensions: [".jsonl", ".json"],
        sessionFormat: .genericMtime
    ),
]

/// Compiles each candidate's process matchers on demand and returns the
/// first `AgentKind` whose patterns match `command`, mirroring
/// `matchAgentKind` in the TypeScript policy: patterns are tried in
/// declaration order (first match wins) and each pattern's case-sensitivity
/// is applied exactly as declared — most are `/i` (case-insensitive), but
/// the five scoped-package patterns above are intentionally not, matching
/// non-global JS `RegExp.test` semantics (a plain "does this match
/// anywhere" check, no lastIndex state).
public func matchAgentKind(command: String) -> AgentKind? {
    let fullRange = NSRange(command.startIndex..<command.endIndex, in: command)
    for kind in AGENT_KINDS {
        for matcher in kind.processMatchers {
            var options: NSRegularExpression.Options = []
            if matcher.caseInsensitive { options.insert(.caseInsensitive) }
            guard let regex = try? NSRegularExpression(pattern: matcher.pattern, options: options) else {
                continue
            }
            if regex.firstMatch(in: command, options: [], range: fullRange) != nil {
                return kind
            }
        }
    }
    return nil
}
