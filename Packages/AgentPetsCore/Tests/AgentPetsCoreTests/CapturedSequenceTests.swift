import Foundation
import Testing
@testable import AgentPetsCore

private func fixture(_ tool: String, _ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/\(tool)"))
    return try Data(contentsOf: url)
}

/// 実 fixture を本物の HookNormalizer に通し、ts だけ差し替えて時間差を再現する。
private func step(_ source: Source, _ name: String, at ts: Double) throws -> AgentEvent {
    let tool = source == .claude ? "claude" : "codex"
    return try #require(HookNormalizer.normalize(source: source, stdin: try fixture(tool, name), now: ts))
}

private func apply(_ events: [AgentEvent], to table: SessionTable = SessionTable()) -> SessionTable {
    events.reduce(table) { SessionReducer.apply($1, to: $0) }
}

private func status(_ t: SessionTable) -> PetStatus? { t.sessions.values.first?.status }

@Suite("採取 fixture の時系列")
struct CapturedSequenceTests {
    @Test("Claude C1: UserPromptSubmit → PreToolUse → PermissionRequest → PostToolUse → Stop")
    func claudeC1() throws {
        var t = SessionTable()
        let steps: [(String, Double, PetStatus)] = [
            ("UserPromptSubmit", 0, .working),
            ("PreToolUse", 1.0, .working),
            ("PermissionRequest", 1.054, .waiting),
            ("PostToolUse", 6.954, .working),
            ("Stop", 8.0, .success),
        ]
        for (name, ts, expected) in steps {
            t = apply([try step(.claude, name, at: ts)], to: t)
            #expect(status(t) == expected, "\(name)")
        }
    }

    @Test("Codex 自動承認: PermissionRequest と PreToolUse が同時、PostToolUse で working（waiting に固着しない）")
    func codexAutoApprove() throws {
        let t = apply([try step(.codex, "PermissionRequest", at: 100), try step(.codex, "PreToolUse", at: 100),
                       try step(.codex, "PostToolUse", at: 103.1)])
        #expect(status(t) == .working)
    }

    @Test("Codex 拒否: PermissionRequest → Interrupt で idle")
    func codexDeny() throws {
        let t = apply([try step(.codex, "PermissionRequest", at: 100), try step(.codex, "Interrupt", at: 103.6)])
        #expect(status(t) == .idle)
    }

    @Test("Codex 到着順の逆転: PreToolUse(T+0.0001) が先に適用されても PermissionRequest(T) で waiting")
    func codexInvertedArrival() throws {
        let t = apply([try step(.codex, "PreToolUse", at: 100.0001), try step(.codex, "PermissionRequest", at: 100)])
        #expect(status(t) == .waiting)
    }

    @Test("Claude permission_prompt 再入: PermissionRequest@0 → Notification@6.0 → PostToolUse@6.6 で working")
    func claudePermissionPromptReentry() throws {
        let t = apply([try step(.claude, "PermissionRequest", at: 0),
                       try step(.claude, "Notification-permission_prompt", at: 6.0),
                       try step(.claude, "PostToolUse", at: 6.6)])
        #expect(status(t) == .working)
    }
}
