import Foundation

/// Codex の hook 対応表。spec §1.1。
/// 出典: https://learn.chatgpt.com/docs/hooks.md（2026-10-10 取得）と Task 1 の採取記録。
public enum CodexNormalizer {
    static func map(_ input: HookInput) -> (EventKind, String, ActivityPhase?)? {
        switch input.event {
        case "SessionStart": return (.sessionStarted, "", nil)
        case "SessionEnd": return (.sessionEnded, "", nil)
        case "UserPromptSubmit": return (.turnStarted, "", nil)
        case "PreToolUse": return (.activity, input.toolName, .pre)
        case "PostToolUse": return (.activity, input.toolName, .post)
        case "PermissionRequest": return (.inputRequested, input.toolName, nil)
        case "Stop": return (.turnCompleted, "", nil)
        case "Interrupt": return (.turnInterrupted, "", nil)
        default: return nil
        }
    }
}
