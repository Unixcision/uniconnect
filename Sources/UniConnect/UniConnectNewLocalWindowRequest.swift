import Foundation

/// The validated, immutable request produced by the local new-window chooser.
struct UniConnectNewLocalWindowRequest: Equatable, Sendable {
    let visibleName: String
    let boxRoot: String
    let launchTarget: UniConnectLocalWindowLaunchTarget

    init?(
        visibleName: String?,
        boxRoot: String,
        launchTarget: UniConnectLocalWindowLaunchTarget
    ) {
        let normalizedRoot = boxRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRoot.isEmpty else { return nil }
        let normalizedName = visibleName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.visibleName = normalizedName?.isEmpty == false
            ? normalizedName!
            : launchTarget.displayName
        self.boxRoot = normalizedRoot
        self.launchTarget = launchTarget
    }

    /// Input queued after the login shell appears; `nil` means a plain terminal.
    var startupInput: String? {
        launchTarget.startupCommand(boxRoot: boxRoot).map { $0 + "\n" }
    }
}
