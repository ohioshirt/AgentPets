import Foundation

public struct SessionKey: Hashable, Sendable {
    public var source: Source
    public var session: String

    public init(source: Source, session: String) {
        self.source = source
        self.session = session
    }
}

public struct SessionState: Equatable, Sendable {
    public var key: SessionKey
    public var project: String
    public var status: PetStatus
    /// working ならツール名、waiting なら許可待ちのツール名、error なら補足。
    public var detail: String
    /// 最後に適用したイベントの ts。順序保護と TTL の基準。
    public var lastAppliedTS: Double
    /// 今の状態に入った ts。猶予の起点。
    public var enteredTS: Double
    /// turn.completed を受けた回数。同じ ts・同じ文の完了が連投されても表が変化したと分かるようにする
    /// （HubStore が「表が変わったときだけ跳ねる」と判定するため。manual の連投で毎回跳ねる）。
    public var completionCount: Int
}

public struct SessionTable: Equatable, Sendable {
    public internal(set) var sessions: [SessionKey: SessionState] = [:]
    public init() {}
}

/// spec §2 の設定値。
public struct ReducerConfig: Sendable {
    public var grace: Double = 1.0
    public var workingTTL: Double = 30 * 60
    public var waitingTTL: Double = 30 * 60
    public var errorTTL: Double = 30 * 60
    public var sessionTTL: Double = 2 * 60 * 60
    public var manualWorkingTTL: Double = 10
    public var manualTTL: Double = 10 * 60
    /// これより大きく過去の ts は並行起動の揺れではなく時計の変化とみなし、受け入れる。
    public var clockJumpTolerance: Double = 10

    public init() {}
}

public enum SessionReducer {
    public static func apply(_ event: AgentEvent, to table: SessionTable,
                             config: ReducerConfig = .init()) -> SessionTable {
        let key = SessionKey(source: event.source, session: event.session)
        var table = table

        if event.kind == .sessionEnded {
            table.sessions[key] = nil
            return table
        }

        let existing = table.sessions[key]
        var state = existing ?? SessionState(key: key, project: event.project, status: .idle, detail: "",
                                             lastAppliedTS: event.ts, enteredTS: event.ts, completionCount: 0)

        if let existing {
            let lag = existing.lastAppliedTS - event.ts
            if lag > 0 && lag <= config.clockJumpTolerance { return table }
        }
        if !event.project.isEmpty { state.project = event.project }

        func enter(_ status: PetStatus, detail: String) {
            state.status = status
            state.detail = detail
            state.enteredTS = event.ts
        }

        switch event.kind {
        case .sessionEnded:
            return table
        case .sessionStarted:
            break
        // hook 由来の turn.* は detail が空。manual は旧形式の message を detail に持つので、そのまま渡す。
        case .turnStarted:
            enter(.working, detail: event.detail)
        case .activity:
            guard shouldAccept(activity: event, in: state, config: config) else { return table }
            enter(.working, detail: event.detail)
        case .inputRequested:
            if state.status == .waiting && event.detail.isEmpty {
                state.enteredTS = event.ts
            } else {
                enter(.waiting, detail: event.detail)
            }
        case .turnCompleted:
            enter(.success, detail: event.detail)
            state.completionCount += 1
        case .turnFailed:
            enter(.error, detail: event.detail)
        case .turnInterrupted:
            enter(.idle, detail: event.detail)
        case .agentIdle:
            if state.status == .waiting || state.status == .working { enter(.idle, detail: "") }
        }

        // ここに来るのは ts が新しいか、時計の変化として受け入れた古いイベント。
        // 後者で max を取ると旧時刻が残り、以後のイベントが落ち続け TTL も効かなくなる。
        state.lastAppliedTS = event.ts
        table.sessions[key] = state
        return table
    }

    private static func shouldAccept(activity event: AgentEvent, in state: SessionState,
                                     config: ReducerConfig) -> Bool {
        switch state.status {
        case .idle, .working:
            return true
        case .success, .error:
            return event.ts - state.enteredTS > config.grace
        case .waiting:
            guard event.ts - state.enteredTS > config.grace else { return false }
            if state.detail.isEmpty { return true }
            return event.phase == .post && event.detail == state.detail
        }
    }

    public static func expire(_ table: SessionTable, now: Double,
                              config: ReducerConfig = .init()) -> SessionTable {
        var table = table
        for (key, state) in table.sessions {
            let age = now - state.lastAppliedTS
            let isManual = key.source == .manual
            if age >= (isManual ? config.manualTTL : config.sessionTTL) {
                table.sessions[key] = nil
                continue
            }
            let ttl: Double?
            switch state.status {
            case .working: ttl = isManual ? config.manualWorkingTTL : config.workingTTL
            case .waiting: ttl = config.waitingTTL
            case .error: ttl = config.errorTTL
            case .idle, .success: ttl = nil
            }
            if let ttl, age >= ttl {
                var idle = state
                idle.status = .idle
                idle.detail = ""
                idle.enteredTS = now
                table.sessions[key] = idle
            }
        }
        return table
    }
}
