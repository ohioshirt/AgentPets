import Foundation

/// アダプタとアプリの間の wire 形式。spec §1.2。
public enum WireCodec {
    /// バンドルIDがまだプレースホルダなので、それとは独立した固定名にしている。
    public static let notificationName = "com.agentpets.status"

    public static func encode(_ event: AgentEvent) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(event) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// v2 か旧形式を受け付ける。同一ログインセッションの任意のプロセスが送れるので、
    /// 型に合わないものは捨て、文字列は整形してから返す。
    public static func decode(_ raw: String?, now: Double) -> AgentEvent? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        if let probe = try? JSONDecoder().decode(VersionProbe.self, from: data), let v = probe.v {
            guard v == 2, var event = try? JSONDecoder().decode(AgentEvent.self, from: data) else { return nil }
            event.project = MessageText.sanitize(event.project)
            event.detail = MessageText.sanitize(event.detail)
            return event
        }
        guard let legacy = try? JSONDecoder().decode(Legacy.self, from: data),
              let status = PetStatus(rawValue: legacy.status) else { return nil }
        return AgentEvent(source: .manual, session: "manual", project: "",
                          kind: legacyKind(status),
                          detail: MessageText.sanitize(legacy.message ?? ""), ts: now)
    }

    private static func legacyKind(_ status: PetStatus) -> EventKind {
        switch status {
        case .idle: return .turnInterrupted
        case .working: return .turnStarted
        case .waiting: return .inputRequested
        case .success: return .turnCompleted
        case .error: return .turnFailed
        }
    }

    private struct VersionProbe: Decodable { let v: Int? }
    private struct Legacy: Decodable {
        let status: String
        let message: String?
    }
}
