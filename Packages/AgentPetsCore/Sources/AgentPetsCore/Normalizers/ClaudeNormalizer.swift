import Foundation

/// Claude Code の hook 対応表。spec §1.1。
/// 出典: https://code.claude.com/docs/en/hooks（2026-10-10 取得）と Task 1 の採取記録。
public enum ClaudeNormalizer {
    /// Notification の matcher 値が入る stdin のキー。docs の記載どおりで、Task 1 の採取で確かめた。
    /// 採取結果が異なる場合はこの値を記録どおりに直す。
    public static let notificationTypeKey = "notification_type"

    static func map(_ input: HookInput) -> (EventKind, String, ActivityPhase?)? {
        switch input.event {
        case "SessionStart": return (.sessionStarted, "", nil)
        case "SessionEnd": return (.sessionEnded, "", nil)
        case "UserPromptSubmit": return (.turnStarted, "", nil)
        case "PreToolUse": return (.activity, input.toolName, .pre)
        case "PostToolUse", "PostToolUseFailure": return (.activity, input.toolName, .post)
        case "PermissionRequest": return (.inputRequested, input.toolName, nil)
        case "Stop": return (.turnCompleted, "", nil)
        case "StopFailure": return (.turnFailed, "", nil)
        case "Notification":
            switch input.string(notificationTypeKey) {
            case "permission_prompt", "elicitation_dialog": return (.inputRequested, "", nil)
            case "idle_prompt": return (.agentIdle, "", nil)
            default: return nil
            }
        default: return nil
        }
    }
}
