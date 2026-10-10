import Foundation
import Testing
@testable import AgentPetsCore

private func fixture(_ tool: String, _ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/\(tool)"))
    return try Data(contentsOf: url)
}

/// 実 fixture の hook_event_name だけを差し替える。採取できないイベント用。
private func retargeted(_ data: Data, event: String) throws -> Data {
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["hook_event_name"] = event
    return try JSONSerialization.data(withJSONObject: object)
}

@Suite("ClaudeNormalizer")
struct ClaudeNormalizerTests {
    @Test("各 fixture が期待する kind になる",
          arguments: [
            ("SessionStart", EventKind.sessionStarted),
            ("SessionEnd", .sessionEnded),
            ("UserPromptSubmit", .turnStarted),
            ("PreToolUse", .activity),
            ("PostToolUse", .activity),
            ("PostToolUseFailure", .activity),
            ("PermissionRequest", .inputRequested),
            ("Notification-permission_prompt", .inputRequested),
            ("Notification-idle_prompt", .agentIdle),
            ("Stop", .turnCompleted),
          ])
    func mapsFixture(name: String, kind: EventKind) throws {
        let event = try #require(HookNormalizer.normalize(source: .claude, stdin: try fixture("claude", name), now: 7))
        #expect(event.kind == kind)
        #expect(event.source == .claude)
        #expect(!event.session.isEmpty)
        #expect(event.project == "demo-project")
        #expect(event.ts == 7)
    }

    @Test("PreToolUse は pre、PostToolUse と PostToolUseFailure は post で tool 名を detail に持つ")
    func activityPhaseAndDetail() throws {
        let pre = try #require(HookNormalizer.normalize(source: .claude, stdin: try fixture("claude", "PreToolUse"), now: 0))
        let post = try #require(HookNormalizer.normalize(source: .claude, stdin: try fixture("claude", "PostToolUse"), now: 0))
        let failure = try #require(HookNormalizer.normalize(source: .claude, stdin: try fixture("claude", "PostToolUseFailure"), now: 0))
        #expect(pre.phase == .pre)
        #expect(post.phase == .post)
        #expect(failure.phase == .post)
        #expect(!pre.detail.isEmpty)
    }

    @Test("PermissionRequest は tool 名を detail に持つ")
    func permissionDetail() throws {
        let event = try #require(HookNormalizer.normalize(source: .claude, stdin: try fixture("claude", "PermissionRequest"), now: 0))
        #expect(!event.detail.isEmpty)
    }

    @Test("StopFailure は turn.failed（Stop の実 fixture のイベント名だけ差し替え）")
    func stopFailure() throws {
        let data = try retargeted(try fixture("claude", "Stop"), event: "StopFailure")
        #expect(HookNormalizer.normalize(source: .claude, stdin: data, now: 0)?.kind == .turnFailed)
    }

    @Test("サブエージェント内のイベントは捨てる")
    func dropsSubagent() throws {
        #expect(HookNormalizer.normalize(source: .claude, stdin: try fixture("claude", "PreToolUse-subagent"), now: 0) == nil)
    }

    @Test("SubagentStart / SubagentStop は捨てる", arguments: ["SubagentStart", "SubagentStop"])
    func dropsSubagentLifecycle(event: String) throws {
        let data = try retargeted(try fixture("claude", "Stop"), event: event)
        #expect(HookNormalizer.normalize(source: .claude, stdin: data, now: 0) == nil)
    }

    @Test("未知のイベントは捨てる")
    func dropsUnknown() throws {
        let data = try retargeted(try fixture("claude", "Stop"), event: "PreCompact")
        #expect(HookNormalizer.normalize(source: .claude, stdin: data, now: 0) == nil)
    }

    @Test("対象外の Notification matcher は捨てる", arguments: ["agent_needs_input", "auth_success", "quota_auto_resume_fired"])
    func dropsOtherNotifications(type: String) throws {
        var object = try #require(try JSONSerialization.jsonObject(with: try fixture("claude", "Notification-idle_prompt")) as? [String: Any])
        object[ClaudeNormalizer.notificationTypeKey] = type
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(HookNormalizer.normalize(source: .claude, stdin: data, now: 0) == nil)
    }

    @Test("session_id が無い・空なら捨てる", arguments: [nil, ""] as [String?])
    func dropsMissingSession(session: String?) throws {
        var object = try #require(try JSONSerialization.jsonObject(with: try fixture("claude", "Stop")) as? [String: Any])
        // String? をそのまま代入すると Optional が値として入るので、nil は明示的に消す
        if let session { object["session_id"] = session } else { object.removeValue(forKey: "session_id") }
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(HookNormalizer.normalize(source: .claude, stdin: data, now: 0) == nil)
    }

    @Test("壊れた入力と空入力は捨てる")
    func dropsMalformed() {
        #expect(HookNormalizer.normalize(source: .claude, stdin: Data(), now: 0) == nil)
        #expect(HookNormalizer.normalize(source: .claude, stdin: Data("{".utf8), now: 0) == nil)
        #expect(HookNormalizer.normalize(source: .claude, stdin: Data("[]".utf8), now: 0) == nil)
    }

    @Test("cwd が無ければ project は空")
    func missingCwd() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: try fixture("claude", "Stop")) as? [String: Any])
        object["cwd"] = nil
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(HookNormalizer.normalize(source: .claude, stdin: data, now: 0)?.project == "")
    }
}

@Suite("CodexNormalizer")
struct CodexNormalizerTests {
    @Test("各 fixture が期待する kind になる",
          arguments: [
            ("SessionStart", EventKind.sessionStarted),
            ("SessionEnd", .sessionEnded),
            ("UserPromptSubmit", .turnStarted),
            ("PreToolUse", .activity),
            ("PostToolUse", .activity),
            ("PermissionRequest", .inputRequested),
            ("Stop", .turnCompleted),
            ("Interrupt", .turnInterrupted),
          ])
    func mapsFixture(name: String, kind: EventKind) throws {
        let event = try #require(HookNormalizer.normalize(source: .codex, stdin: try fixture("codex", name), now: 7))
        #expect(event.kind == kind)
        #expect(event.source == .codex)
        #expect(event.project == "demo-project")
    }

    @Test("SubagentStart / SubagentStop は捨てる", arguments: ["SubagentStart", "SubagentStop"])
    func dropsSubagentLifecycle(event: String) throws {
        let data = try retargeted(try fixture("codex", "Stop"), event: event)
        #expect(HookNormalizer.normalize(source: .codex, stdin: data, now: 0) == nil)
    }

    @Test("agent_id 付きは捨てる")
    func dropsAgentID() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: try fixture("codex", "PreToolUse")) as? [String: Any])
        object["agent_id"] = "sub-1"
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(HookNormalizer.normalize(source: .codex, stdin: data, now: 0) == nil)
    }

    @Test("Claude 専用のイベントは Codex では捨てる", arguments: ["Notification", "StopFailure"])
    func dropsClaudeOnly(event: String) throws {
        let data = try retargeted(try fixture("codex", "Stop"), event: event)
        #expect(HookNormalizer.normalize(source: .codex, stdin: data, now: 0) == nil)
    }
}

@Suite("HookNormalizer")
struct HookNormalizerTests {
    @Test("manual は hook 経路では受け付けない")
    func rejectsManual() throws {
        #expect(HookNormalizer.normalize(source: .manual, stdin: try fixture("claude", "Stop"), now: 0) == nil)
    }
}
