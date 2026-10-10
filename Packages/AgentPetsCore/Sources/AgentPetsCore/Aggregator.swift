import Foundation

/// 画面と（第 2 期の）BLE に出す 1 つの状態。
public struct DisplayState: Equatable, Sendable {
    public var status: PetStatus
    /// 吹き出しの文。狭い吹き出しでも状態語が切れないよう、状態を先頭に置く。
    public var message: String
    /// ホバー時に出す全文（`<source> · <project>: <状態>[ (<detail>)]`）。吹き出しが空なら空。
    public var tooltip: String
    /// StackChan に送る文（spec §2.1）。状態の語は含めない。hook は `<detail> · <project|source>`、manual は送られた文そのもの。
    public var subtitle: String
    public var sessionKey: SessionKey?
    /// 表示中セッションが今まさに turn.completed を受けた。跳ねる合図。
    /// 集約は立てない。HubStore.receive が、適用したイベントと表示中セッションが一致したときだけ立てる。
    public var celebrate: Bool

    public static let empty = DisplayState(status: .idle, message: "", tooltip: "", subtitle: "", sessionKey: nil, celebrate: false)

    public init(status: PetStatus, message: String, tooltip: String = "", subtitle: String = "",
                sessionKey: SessionKey?, celebrate: Bool = false) {
        self.status = status
        self.message = message
        self.tooltip = tooltip
        self.subtitle = subtitle
        self.sessionKey = sessionKey
        self.celebrate = celebrate
    }

    /// celebrate を除いて同じ見た目か。HubStore の重複排除に使う。
    public func sameView(as other: DisplayState) -> Bool {
        status == other.status && message == other.message && tooltip == other.tooltip
            && subtitle == other.subtitle && sessionKey == other.sessionKey
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
        let t = texts(for: top)
        return DisplayState(status: top.status, message: t.message, tooltip: t.tooltip, subtitle: t.subtitle,
                            sessionKey: top.key)
    }

    /// 吹き出しの文とツールチップ。吹き出しは `<状態>[ (<detail>)] · <project|source>`、
    /// ツールチップは `<source> · <project>: <状態>[ (<detail>)]`（project が空なら `<source>: …`）。
    /// StackChan の文は `<detail> · <project|source>`（detail が空なら `<project|source>`）。状態の語はファームウェアが出す。
    private static func texts(for state: SessionState) -> (message: String, tooltip: String, subtitle: String) {
        // manual は状態に関係なく送られた文を出す（idle でも文があれば StackChan に送る。spec §2.1）。
        if state.key.source == .manual {
            let text = MessageText.sanitize(state.detail)
            return (text, text, text)
        }
        guard state.status != .idle else { return ("", "", "") }
        let source = state.key.source.rawValue
        let place = state.project.isEmpty ? source : state.project
        let subtitle = state.detail.isEmpty ? place : "\(state.detail) · \(place)"
        let body = state.detail.isEmpty
            ? state.status.phrase
            : "\(state.status.phrase) (\(state.detail))"
        let bubble = "\(body) · \(place)"
        let full = state.project.isEmpty
            ? "\(source): \(body)"
            : "\(source) · \(state.project): \(body)"
        return (MessageText.sanitize(bubble), MessageText.sanitize(full), MessageText.sanitize(subtitle))
    }
}
