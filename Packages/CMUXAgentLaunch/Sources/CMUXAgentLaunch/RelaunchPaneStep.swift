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
        case let .backgroundWorkQuestion(option):
            // Chosen by its number, read from the option's own text. Leaving the watchers running
            // would strand them: the resumed conversation starts its own and two end up looking at
            // the same thing.
            .type(String(option))
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
