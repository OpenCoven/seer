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

/// Mirrors `AgentKind` in `main/services/agent-detection-policy.ts`.
/// Regex patterns are kept as raw ICU-compatible pattern strings (not
/// precompiled `NSRegularExpression`s) so this value stays a plain,
/// unconditionally `Sendable` value type; `matchAgentKind` compiles them
/// on demand.
public struct AgentKind: Equatable, Sendable {
    public let id: AgentFamily
    public let name: String
    public let processMatcherPatterns: [String]
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
        processMatcherPatterns: [String],
        sessionRoots: [String],
        sessionExtensions: [String],
        sessionFileNames: [String]? = nil,
        sessionFormat: SessionFormat,
        requireSessionTurn: Bool = false,
        allowProcessFallback: Bool = false
    ) {
        self.id = id
        self.name = name
        self.processMatcherPatterns = processMatcherPatterns
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
        processMatcherPatterns: [
            #"(^|[/\s])claude(\s|$)"#,
            #"@anthropic-ai/claude-code"#,
            #"claude[-_]code"#,
        ],
        sessionRoots: [".claude/projects"],
        sessionExtensions: [".jsonl"],
        sessionFormat: .claude,
        requireSessionTurn: true
    ),
    AgentKind(
        id: .codex,
        name: "Codex",
        processMatcherPatterns: [
            #"(^|[/\s])codex(\s|$)"#,
            #"@openai/codex"#,
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
        processMatcherPatterns: [
            #"(^|[/\s])grok(\s|$)"#,
            #"\.grok/(?:bin|downloads)/"#,
            #"grok-\d+\.\d+\.\d+-macos"#,
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
        processMatcherPatterns: [
            #"(^|[/\s])gemini(\s|$)"#,
            #"@google/gemini-cli"#,
        ],
        sessionRoots: [".gemini"],
        sessionExtensions: [".jsonl", ".json"],
        sessionFormat: .genericMtime
    ),
    AgentKind(
        id: .aider,
        name: "Aider",
        processMatcherPatterns: [#"(^|[/\s])aider(\s|$)"#],
        sessionRoots: [],
        sessionExtensions: [],
        sessionFormat: .none
    ),
    AgentKind(
        id: .opencode,
        name: "OpenCode",
        processMatcherPatterns: [#"(^|[/\s])opencode(\s|$)"#],
        sessionRoots: [".local/share/opencode", ".config/opencode"],
        sessionExtensions: [".jsonl", ".json"],
        sessionFormat: .genericMtime
    ),
    AgentKind(
        id: .goose,
        name: "Goose",
        processMatcherPatterns: [#"(^|[/\s])goose(\s|$)"#],
        sessionRoots: [".config/goose"],
        sessionExtensions: [".jsonl", ".json"],
        sessionFormat: .genericMtime
    ),
    AgentKind(
        id: .amp,
        name: "Amp",
        processMatcherPatterns: [
            #"(^|[/\s])amp(\s|$)"#,
            #"@sourcegraph/amp"#,
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
        processMatcherPatterns: [
            #"(^|[/\s])cursor-agent(\s|$)"#,
            #"cursor-agent-svc"#,
            #"cursor(?:-agent)?(?:\.js)?\s+--agent\b"#,
        ],
        sessionRoots: [],
        sessionExtensions: [],
        sessionFormat: .cursor,
        allowProcessFallback: true
    ),
    AgentKind(
        id: .continueAgent,
        name: "Continue",
        processMatcherPatterns: [
            #"continue-cli"#,
            #"@continuedev/cli"#,
        ],
        sessionRoots: [".continue/sessions"],
        sessionExtensions: [".jsonl", ".json"],
        sessionFormat: .genericMtime
    ),
]

/// Compiles each candidate's process-matcher patterns on demand and returns
/// the first `AgentKind` whose patterns match `command`, mirroring
/// `matchAgentKind` in the TypeScript policy (case-insensitive, first match
/// wins in declaration order).
public func matchAgentKind(command: String) -> AgentKind? {
    let fullRange = NSRange(command.startIndex..<command.endIndex, in: command)
    for kind in AGENT_KINDS {
        for pattern in kind.processMatcherPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            if regex.firstMatch(in: command, options: [], range: fullRange) != nil {
                return kind
            }
        }
    }
    return nil
}
