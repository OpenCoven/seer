import Foundation

/// Injectable detector abstraction, so `AgentMonitor` (and its tests) can
/// depend on "something that produces `ActiveAgent`s" without depending on
/// `AgentDetector`'s concrete process/session wiring.
public protocol AgentDetecting: Sendable {
    func detect(now: Int64) async throws -> [ActiveAgent]
}

/// Merges process evidence (`ProcessSnapshotProviding`) and session/
/// transcript evidence (`SessionSnapshotProviding`) into the exact
/// `ActiveAgent` list the renderer bridge expects, mirroring
/// `detectActiveAgents` in `main/services/agent-detector.ts` (minus the
/// experimental Raycast log heuristic, which is out of scope for native
/// detection). A stateless value type: all per-scan state lives in the
/// two injected sources, not here.
public struct AgentDetector: AgentDetecting {
    private let processes: ProcessSnapshotProviding
    private let sessions: SessionSnapshotProviding

    public init(processes: ProcessSnapshotProviding, sessions: SessionSnapshotProviding) {
        self.processes = processes
        self.sessions = sessions
    }

    /// Fetches both sources concurrently and merges them. Either source
    /// throwing propagates that failure to the caller as-is — a scan is
    /// either a fully-evidenced success or an intentional failure, never a
    /// partial result silently reported as a clean empty scan (the caller,
    /// `AgentMonitor`, is responsible for retaining prior state on
    /// failure).
    public func detect(now: Int64) async throws -> [ActiveAgent] {
        async let processSnapshotsTask = processes.snapshot()
        async let sessionEvidenceTask = sessions.snapshot(now: now)
        let (processSnapshots, sessionEvidence) = try await (processSnapshotsTask, sessionEvidenceTask)

        var processesByFamily: [AgentFamily: [ProcessSnapshot]] = [:]
        for snapshot in processSnapshots {
            guard let kind = matchAgentKind(command: snapshot.command) else { continue }
            processesByFamily[kind.id, default: []].append(snapshot)
        }

        var sessionsByFamily: [AgentFamily: [SessionTurnEvidence]] = [:]
        for turn in sessionEvidence {
            sessionsByFamily[turn.family, default: []].append(turn)
        }

        var agents: [ActiveAgent] = []

        for kind in AGENT_KINDS {
            let kindProcesses = processesByFamily[kind.id] ?? []
            // Stable "first max" selection, matching a stable sort by
            // descending cpuPercent followed by taking the first element:
            // `max(by:)` keeps the first-encountered element on ties
            // because it only replaces its running max when the next
            // element is *strictly* greater.
            let topProcess = kindProcesses.max { lhs, rhs in
                (lhs.cpuPercent ?? -Double.infinity) < (rhs.cpuPercent ?? -Double.infinity)
            }

            // Sort by descending activity, with an explicit tie break on
            // `identity` so the merge order is fully deterministic
            // regardless of the sessions provider's own enumeration
            // order — never relying only on `sort`'s documented stability.
            let activeTurns = (sessionsByFamily[kind.id] ?? []).sorted { lhs, rhs in
                if lhs.lastActivityAt != rhs.lastActivityAt { return lhs.lastActivityAt > rhs.lastActivityAt }
                return lhs.identity < rhs.identity
            }

            if !activeTurns.isEmpty {
                let source: AgentActivitySource = topProcess == nil ? .session : .both
                for turn in activeTurns {
                    agents.append(ActiveAgent(
                        id: "\(kind.id.rawValue):\(turn.identity)",
                        name: kind.name,
                        detail: buildFriendlyDetail(projectLabel: turn.label, reason: turn.reason),
                        source: source,
                        pid: topProcess?.pid,
                        cpuPercent: topProcess?.cpuPercent,
                        lastActivityAt: turn.lastActivityAt
                    ))
                }
                continue
            }

            // Process-only fallback for agents without reliable session
            // logs. Intentionally strict: idle CLIs often sit at a few %
            // CPU, and a first-ever process sample can never qualify
            // (`ProcessSnapshot.cpuPercent` is `nil` until a second sample
            // exists — see `NativeProcessSnapshotSource`), so a freshly
            // observed process can never falsely trigger this path.
            let allowProcessFallback = !kind.requireSessionTurn && (kind.sessionFormat == .none || kind.allowProcessFallback)
            guard allowProcessFallback else { continue }

            let busyProcesses = kindProcesses.filter { snapshot in
                guard let cpuPercent = snapshot.cpuPercent, cpuPercent.isFinite else { return false }
                return cpuPercent >= processOnlyCPUThreshold
            }
            for process in busyProcesses {
                agents.append(ActiveAgent(
                    id: "\(kind.id.rawValue):pid:\(process.pid)",
                    name: kind.name,
                    detail: buildFriendlyDetail(projectLabel: nil, processOnly: true),
                    source: .process,
                    pid: process.pid,
                    cpuPercent: process.cpuPercent,
                    lastActivityAt: now
                ))
            }
        }

        // Final ordering: descending activity, with an explicit `id`
        // tie break so the merged result is fully deterministic across
        // families/process-only entries sharing the same `lastActivityAt`
        // (e.g. every process-only fallback entry stamps `now`).
        agents.sort { lhs, rhs in
            if lhs.lastActivityAt != rhs.lastActivityAt { return lhs.lastActivityAt > rhs.lastActivityAt }
            return lhs.id < rhs.id
        }
        return agents
    }
}
