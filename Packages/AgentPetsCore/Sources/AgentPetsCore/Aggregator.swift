import Foundation

/// 画面と（第 2 期の）BLE に出す 1 つの状態。
public struct DisplayState: Equatable, Sendable {
    public var status: PetStatus
    public var message: String
    public var sessionKey: SessionKey?
    /// 表示中セッションが今まさに turn.completed を受けた。跳ねる合図。
    /// 集約は立てない。HubStore.receive が、適用したイベントと表示中セッションが一致したときだけ立てる。
    public var celebrate: Bool

    public static let empty = DisplayState(status: .idle, message: "", sessionKey: nil, celebrate: false)

    public init(status: PetStatus, message: String, sessionKey: SessionKey?, celebrate: Bool = false) {
        self.status = status
        self.message = message
        self.sessionKey = sessionKey
        self.celebrate = celebrate
    }

    /// celebrate を除いて同じ見た目か。HubStore の重複排除に使う。
    public func sameView(as other: DisplayState) -> Bool {
        status == other.status && message == other.message && sessionKey == other.sessionKey
    }
}

extension PetStatus {
    /// spec §2.3。大きいほど優先。
    public var priority: Int {
        switch self {
        case .waiting: return 4
        case .error: return 3
        case .working: return 2
        case .success: return 1
        case .idle: return 0
        }
    }

    var phrase: String {
        switch self {
        case .idle: return ""
        case .working: return "作業中"
        case .waiting: return "入力待ち"
        case .success: return "完了"
        case .error: return "失敗"
        }
    }
}

public enum Aggregator {
    public static func display(_ table: SessionTable) -> DisplayState {
        let top = table.sessions.values.max { a, b in
            (a.status.priority, a.lastAppliedTS) < (b.status.priority, b.lastAppliedTS)
        }
        guard let top else { return .empty }
        return DisplayState(status: top.status, message: message(for: top), sessionKey: top.key)
    }

    private static func message(for state: SessionState) -> String {
        if state.key.source == .manual { return MessageText.sanitize(state.detail) }
        guard state.status != .idle else { return "" }
        let head = state.project.isEmpty
            ? state.key.source.rawValue
            : "\(state.key.source.rawValue) · \(state.project)"
        let tail = state.detail.isEmpty ? "" : " (\(state.detail))"
        return MessageText.sanitize("\(head): \(state.status.phrase)\(tail)")
    }
}
