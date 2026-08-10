import Foundation

/// Shared domain types mirroring the wire contract defined in
/// `renderer/bridge/types.ts`. These types describe the exact JSON shape
/// exchanged between the standalone native host and the renderer bridge —
/// every field name, optionality, and timestamp representation here must
/// match the TypeScript source exactly. Timestamps are Unix milliseconds
/// encoded as JSON numbers (`Int64`), and enums are encoded as their raw
/// lowercase string values, matching TypeScript string literal unions.

/// Mirrors `KeepAwakeMode` in `renderer/bridge/types.ts`.
public enum KeepAwakeMode: String, Codable, Equatable, Sendable {
    case system
    case display
}

/// Mirrors `AgentActivitySource` in `renderer/bridge/types.ts`.
public enum AgentActivitySource: String, Codable, Equatable, Sendable {
    case process
    case session
    case both
}

/// Mirrors `ActiveAgent` in `renderer/bridge/types.ts`.
public struct ActiveAgent: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var detail: String
    public var source: AgentActivitySource
    public var pid: Int32?
    public var cpuPercent: Double?
    public var lastActivityAt: Int64

    public init(
        id: String,
        name: String,
        detail: String,
        source: AgentActivitySource,
        pid: Int32? = nil,
        cpuPercent: Double? = nil,
        lastActivityAt: Int64
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.source = source
        self.pid = pid
        self.cpuPercent = cpuPercent
        self.lastActivityAt = lastActivityAt
    }
}

/// Mirrors `AgentMonitorState` in `renderer/bridge/types.ts`.
public struct AgentMonitorState: Codable, Equatable, Sendable {
    public var active: Bool
    public var keepingAwake: Bool
    public var keepAwakeMode: KeepAwakeMode
    public var agents: [ActiveAgent]
    public var lastScanAt: Int64

    public init(
        active: Bool,
        keepingAwake: Bool,
        keepAwakeMode: KeepAwakeMode,
        agents: [ActiveAgent],
        lastScanAt: Int64
    ) {
        self.active = active
        self.keepingAwake = keepingAwake
        self.keepAwakeMode = keepAwakeMode
        self.agents = agents
        self.lastScanAt = lastScanAt
    }
}

/// Mirrors `AgentUsage` in `renderer/bridge/types.ts`.
public struct AgentUsage: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var durationMs: Int64

    public init(id: String, name: String, durationMs: Int64) {
        self.id = id
        self.name = name
        self.durationMs = durationMs
    }
}

/// Mirrors `AwakeSession` in `renderer/bridge/types.ts`.
public struct AwakeSession: Codable, Equatable, Sendable {
    public var id: String
    public var startedAt: Int64
    public var endedAt: Int64?
    public var durationMs: Int64
    public var mode: KeepAwakeMode
    public var agents: [AgentUsage]

    public init(
        id: String,
        startedAt: Int64,
        endedAt: Int64?,
        durationMs: Int64,
        mode: KeepAwakeMode,
        agents: [AgentUsage]
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationMs = durationMs
        self.mode = mode
        self.agents = agents
    }
}

/// Mirrors `HistoryStats` in `renderer/bridge/types.ts`.
public struct HistoryStats: Codable, Equatable, Sendable {
    public var totalAwakeMs: Int64
    public var todayAwakeMs: Int64
    public var sessionCount: Int
    public var perAgent: [AgentUsage]
    public var currentSession: AwakeSession?
    public var recentSessions: [AwakeSession]

    public init(
        totalAwakeMs: Int64,
        todayAwakeMs: Int64,
        sessionCount: Int,
        perAgent: [AgentUsage],
        currentSession: AwakeSession?,
        recentSessions: [AwakeSession]
    ) {
        self.totalAwakeMs = totalAwakeMs
        self.todayAwakeMs = todayAwakeMs
        self.sessionCount = sessionCount
        self.perAgent = perAgent
        self.currentSession = currentSession
        self.recentSessions = recentSessions
    }
}

/// Mirrors `UpdateState` in `renderer/bridge/types.ts`. `releaseURL` is kept
/// as a `String?` (not `URL?`) because the wire contract is a JSON string,
/// and `Foundation.URL`'s `Codable` conformance is not guaranteed to
/// round-trip byte-for-byte with an arbitrary TS string.
public struct UpdateState: Codable, Equatable, Sendable {
    public var checking: Bool
    public var availableVersion: String?
    public var releaseURL: String?
    public var lastCheckedAt: Int64?

    public init(
        checking: Bool,
        availableVersion: String?,
        releaseURL: String?,
        lastCheckedAt: Int64?
    ) {
        self.checking = checking
        self.availableVersion = availableVersion
        self.releaseURL = releaseURL
        self.lastCheckedAt = lastCheckedAt
    }
}

/// Mirrors `Diagnostic` in `renderer/bridge/types.ts`.
public struct Diagnostic: Codable, Equatable, Sendable {
    public var id: String
    public var message: String
    public var occurredAt: Int64

    public init(id: String, message: String, occurredAt: Int64) {
        self.id = id
        self.message = message
        self.occurredAt = occurredAt
    }
}

/// Mirrors `AppSnapshot` in `renderer/bridge/types.ts`.
public struct AppSnapshot: Codable, Equatable, Sendable {
    public var monitor: AgentMonitorState
    public var history: HistoryStats
    public var update: UpdateState
    public var diagnostics: [Diagnostic]
    public var appVersion: String

    public init(
        monitor: AgentMonitorState,
        history: HistoryStats,
        update: UpdateState,
        diagnostics: [Diagnostic],
        appVersion: String
    ) {
        self.monitor = monitor
        self.history = history
        self.update = update
        self.diagnostics = diagnostics
        self.appVersion = appVersion
    }

    /// Matches the TS `EMPTY_STATE` (`renderer/lib/agents.ts`) and
    /// `EMPTY_STATS` (`renderer/lib/history.ts`) defaults, plus the
    /// `update`/`diagnostics` bootstrap shape used before any snapshot has
    /// been fetched: no agents, no history, no pending update check, no
    /// diagnostics, and every timestamp at `0`/`null`.
    public static func empty(version: String) -> AppSnapshot {
        AppSnapshot(
            monitor: AgentMonitorState(
                active: false,
                keepingAwake: false,
                keepAwakeMode: .system,
                agents: [],
                lastScanAt: 0
            ),
            history: HistoryStats(
                totalAwakeMs: 0,
                todayAwakeMs: 0,
                sessionCount: 0,
                perAgent: [],
                currentSession: nil,
                recentSessions: []
            ),
            update: UpdateState(
                checking: false,
                availableVersion: nil,
                releaseURL: nil,
                lastCheckedAt: nil
            ),
            diagnostics: [],
            appVersion: version
        )
    }
}

public extension JSONEncoder {
    /// A `JSONEncoder` configured to encode Seer's domain types exactly like
    /// the TS wire contract: field names unchanged (default `.useDefaultKeys`
    /// key strategy, no snake/camel conversion) and timestamps as raw
    /// `Int64` millisecond numbers (default `.deferredToDate` strategy is
    /// never invoked because no domain type stores a `Date`).
    static var seer: JSONEncoder {
        JSONEncoder()
    }
}

public extension JSONDecoder {
    /// A `JSONDecoder` configured to decode Seer's domain types exactly like
    /// the TS wire contract: field names unchanged (default `.useDefaultKeys`
    /// key strategy) and timestamps read as raw `Int64` millisecond numbers
    /// (no `Date` conversion).
    static var seer: JSONDecoder {
        JSONDecoder()
    }
}
