import Foundation

/// The supported Claude Code lifecycle signals emitted by the remote hook.
public enum ClaudeBridgeEventKind: String, Codable, Sendable, Equatable {
    /// Claude Code's official `Stop` hook, emitted after a response completes.
    case stop

    /// Claude Code's official `Notification` hook with the `idle_prompt` matcher.
    case idlePrompt = "idle_prompt"

    /// Claude Code's official `SessionStart` hook, used only for internal coordination.
    case sessionStart = "session_start"

    /// Claude Code's official `UserPromptSubmit` hook, used only to invalidate stale idle state.
    case userPromptSubmit = "user_prompt_submit"

    /// Whether this lifecycle signal should create a user-visible notification.
    public var isUserVisibleCompletion: Bool {
        switch self {
        case .stop, .idlePrompt:
            return true
        case .sessionStart, .userPromptSubmit:
            return false
        }
    }
}
