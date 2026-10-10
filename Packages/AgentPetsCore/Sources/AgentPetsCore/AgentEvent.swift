import Foundation

/// どのエージェントから来たか。`manual` は旧形式（agentpets-notify.sh）。
public enum Source: String, Codable, Sendable {
    case claude, codex, manual
}

/// ツールに依存しない正規化イベントの種類。spec §1.1。
public enum EventKind: String, Codable, Sendable {
    case sessionStarted = "session.started"
    case sessionEnded = "session.ended"
    case turnStarted = "turn.started"
    case activity
    case inputRequested = "input.requested"
    case turnCompleted = "turn.completed"
    case turnFailed = "turn.failed"
    case turnInterrupted = "turn.interrupted"
    case agentIdle = "agent.idle"
}

/// activity がツール実行の前後どちらで発生したか。waiting を抜ける判定に使う。
public enum ActivityPhase: String, Codable, Sendable {
    case pre, post
}

/// 画面に出す 5 状態。raw 値はアプリの `PetState` と同じ。
public enum PetStatus: String, Codable, Sendable, CaseIterable {
    case idle, working, waiting, success, error
}

public struct AgentEvent: Codable, Equatable, Sendable {
    public var v: Int
    public var source: Source
    public var session: String
    public var project: String
    public var kind: EventKind
    public var detail: String
    public var phase: ActivityPhase?
    /// アダプタ起動時刻（Unix 秒）。
    public var ts: Double

    public init(source: Source, session: String, project: String, kind: EventKind,
                detail: String = "", phase: ActivityPhase? = nil, ts: Double) {
        self.v = 2
        self.source = source
        self.session = session
        self.project = project
        self.kind = kind
        self.detail = detail
        self.phase = phase
        self.ts = ts
    }
}
