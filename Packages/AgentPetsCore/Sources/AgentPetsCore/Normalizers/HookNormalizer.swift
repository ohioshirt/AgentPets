import Foundation

/// hook の stdin を正規化イベントへ変換する入口。ツールごとの対応表は各 Normalizer に置く。
public enum HookNormalizer {
    public static func normalize(source: Source, stdin: Data, now: Double) -> AgentEvent? {
        guard let input = HookInput(stdin) else { return nil }
        // サブエージェント由来は捨てる。spec §1.1。
        if let agentID = input.string("agent_id"), !agentID.isEmpty { return nil }

        let mapped: (EventKind, String, ActivityPhase?)?
        switch source {
        case .claude: mapped = ClaudeNormalizer.map(input)
        case .codex: mapped = CodexNormalizer.map(input)
        case .manual: return nil
        }
        guard let mapped else { return nil }
        let (kind, detail, phase) = mapped
        return AgentEvent(source: source, session: input.session, project: input.project,
                          kind: kind, detail: detail, phase: phase, ts: now)
    }
}

/// 両ツールに共通するフィールドの取り出し。
struct HookInput {
    let object: [String: Any]
    let event: String
    let session: String

    init?(_ data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let event = object["hook_event_name"] as? String,
              let session = object["session_id"] as? String, !session.isEmpty else { return nil }
        self.object = object
        self.event = event
        self.session = session
    }

    func string(_ key: String) -> String? { object[key] as? String }

    var project: String {
        guard let cwd = string("cwd"), !cwd.isEmpty else { return "" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    var toolName: String { string("tool_name") ?? "" }
}
