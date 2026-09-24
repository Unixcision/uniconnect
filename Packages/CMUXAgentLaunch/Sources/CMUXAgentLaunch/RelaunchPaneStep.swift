import Foundation

/// The one thing to do next to a pane, decided from what it is showing.
public enum RelaunchPaneStep: Sendable, Equatable {
    /// Type this text and press return.
    case type(String)
    /// Press return on its own.
    case pressEnter
    /// Nothing more to do; the pane reached what was asked of it.
    case done
    /// Stop and tell the reader why. Nothing is sent.
    case stop(RelaunchCause)
    /// Back out of the question on screen (Escape), leaving the agent as it was, then stop and
    /// tell the reader why.
    case cancelAndStop(RelaunchCause)
}

/// Walks one pane from "agent running" to "agent running again on the same conversation".
///
/// Written as a pure decision so every branch is testable without a terminal, and because the
/// branches are the whole point: three of twenty-six panes were not at a prompt when this was done
/// by hand, and each one needed a different answer.
public struct RelaunchPaneSequencer: Sendable {
    public init() {}

    /// What to do when closing the agent, given what the pane shows.
    public func stepToClose(reading: RelaunchScreenReading) -> RelaunchPaneStep {
        switch reading {
        case .agentReady:
            .type("/exit")
        case .backgroundWorkQuestion:
            // Neither answer is safe: «Exit and stop tasks» kills the agent's monitors and «Keep it
            // running» strands them outside the conversation. Dani's rule is that monitors are
            // saved before a close, never killed, so the close is cancelled and a person decides.
            .cancelAndStop(.backgroundTasks)
        case .exitedShowingResume, .shellPrompt:
            .done
        case .folderTrustQuestion:
            .stop(.folderTrust)
        case .unrecognised:
            .stop(.unknownDialog)
        }
    }

    /// What to do when bringing the agent back, given what the pane shows.
    ///
    /// - Parameter command: the exact line to run, already carrying the conversation and the flags
    ///   the pane had. Relaunching changes nothing else: not permissions, not the model, not the
    ///   folder.
    public func stepToReopen(reading: RelaunchScreenReading, command: String) -> RelaunchPaneStep {
        switch reading {
        case .shellPrompt, .exitedShowingResume:
            .type(command)
        case .agentReady:
            .done
        case .folderTrustQuestion:
            // A permission is given by a person. The question is left on screen and reported.
            .stop(.folderTrust)
        case .backgroundWorkQuestion, .unrecognised:
            .stop(.unknownDialog)
        }
    }
}
