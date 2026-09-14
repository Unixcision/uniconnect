import Foundation

/// How one kind of agent is read and spoken to when relaunching it.
///
/// There is no universal way to close an AI and bring it back: each one prints different things,
/// asks different questions and is resumed with a different line. Claude prints
/// `Resume this session with: <id>` on its way out; Codex does not, and its identity is established
/// from the live process instead. A single hard-coded reader would work for whichever agent it was
/// written against and quietly mangle the rest.
///
/// So the reader is per agent, and an agent without a dialect is **refused, never guessed at**.
public protocol RelaunchAgentDialect: Sendable {
    /// The provider this dialect speaks for, as the host names it (`claude`, `codex`, …).
    var provider: String { get }

    /// Reads what a pane is showing.
    func read(screen: String) -> RelaunchScreenReading

    /// The line that brings the agent back on `sessionID`, keeping `previousArguments`' flags.
    ///
    /// Returns `nil` when this dialect cannot be sure which conversation to resume. That is a
    /// refusal, not a fallback: resuming the wrong conversation is worse than not resuming.
    func relaunchCommand(sessionID: String?, previousArguments: [String]) -> String?
}

/// Picks the dialect for a provider, and refuses when there is none.
public struct RelaunchDialects: Sendable {
    private let byProvider: [String: any RelaunchAgentDialect]

    /// - Parameter dialects: every agent this build knows how to relaunch.
    public init(_ dialects: [any RelaunchAgentDialect]) {
        byProvider = Dictionary(uniqueKeysWithValues: dialects.map { ($0.provider, $0) })
    }

    /// Every agent shipped with a dialect today.
    ///
    /// An agent missing here is not broken: it is reported as ``RelaunchCause/unsupported`` and left
    /// exactly as it was, which is the right answer until somebody writes how it speaks.
    public static let known = RelaunchDialects([ClaudeRelaunchDialect()])

    /// The dialect for `provider`, or `nil` when this build does not know that agent.
    public func dialect(for provider: String) -> (any RelaunchAgentDialect)? {
        byProvider[provider.lowercased()]
    }

    /// The providers this build can relaunch.
    public var supportedProviders: Set<String> { Set(byProvider.keys) }
}
