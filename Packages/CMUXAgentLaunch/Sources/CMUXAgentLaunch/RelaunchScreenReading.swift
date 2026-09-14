import Foundation

/// What a pane is showing right now, read from its captured text.
///
/// Every state here exists because sending keys without looking broke something. A pane is not
/// always at a prompt: it can be sitting on a question, or showing a list where typing goes into a
/// search box instead of the agent. Deciding from the screen is the difference between closing an
/// agent and typing `/exit` into somebody's task description.
public enum RelaunchScreenReading: Sendable, Equatable {
    /// The agent is up and at its prompt.
    case agentReady
    /// The shell is at a prompt; no agent running.
    case shellPrompt
    /// The agent is asking what to do with work it has in flight.
    ///
    /// - Parameter exitOption: the number beside the option that stops the tasks and leaves. It is
    ///   read from the text rather than assumed to be first: an order that shifts between versions
    ///   would otherwise silently pick something else.
    case backgroundWorkQuestion(exitOption: Int)
    /// The agent is asking whether the folder is trusted. Nobody answers this on the reader's behalf.
    case folderTrustQuestion
    /// The agent just left and printed how to resume it.
    case exitedShowingResume(sessionID: String)
    /// Something that is not recognised. Nothing is sent to a pane in this state.
    case unrecognised

    /// Reads `screen`, the text captured from a pane.
    public static func read(screen: String) -> RelaunchScreenReading {
        if screen.contains("Yes, I trust this folder") { return .folderTrustQuestion }

        if screen.contains("Background work is running") {
            guard let option = exitOptionNumber(in: screen) else { return .unrecognised }
            return .backgroundWorkQuestion(exitOption: option)
        }

        if let id = resumeSessionID(in: screen) { return .exitedShowingResume(sessionID: id) }
        if screen.contains("bypass permissions") || screen.contains("shift+tab to cycle") {
            return .agentReady
        }
        if screen.range(of: #"\$ $|% $|❯ $"#, options: .regularExpression) != nil { return .shellPrompt }
        return .unrecognised
    }

    /// The number of the "stop the tasks and leave" option, found by its wording.
    static func exitOptionNumber(in screen: String) -> Int? {
        for line in screen.split(separator: "\n") where line.contains("Exit and stop tasks") {
            let digits = line.drop(while: { !$0.isNumber }).prefix(while: \.isNumber)
            if let value = Int(digits) { return value }
        }
        return nil
    }

    /// The conversation identifier an agent prints on its way out.
    ///
    /// This is the identity worth trusting: the arguments a pane was started with can be silent
    /// about which conversation it ended up on. Measured on a real desktop, 5 of 26 windows had been
    /// launched with no `--resume` at all.
    static func resumeSessionID(in screen: String) -> String? {
        guard screen.contains("Resume this session with") else { return nil }
        let pattern = #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#
        guard let range = screen.range(of: pattern, options: .regularExpression) else { return nil }
        return String(screen[range])
    }
}
