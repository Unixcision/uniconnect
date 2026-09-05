import Foundation

/// The validated, immutable request produced by the local new-window chooser.
struct UniConnectNewLocalWindowRequest: Equatable, Sendable {
    let visibleName: String
    let boxRoot: String
    /// An explicit per-window folder; `nil` follows the workspace default at creation time.
    let workingDirectory: String?
    let launchTarget: UniConnectLocalWindowLaunchTarget

    init?(
        visibleName: String?,
        boxRoot: String,
        workingDirectory: String? = nil,
        launchTarget: UniConnectLocalWindowLaunchTarget
    ) {
        guard let normalizedRoot = UniConnectLocalWindowRecord.validatedBoxRoot(boxRoot) else {
            return nil
        }
        let normalizedWorkingDirectory: String?
        if let workingDirectory {
            guard let validated = UniConnectLocalWindowRecord.validatedWorkingDirectory(
                workingDirectory,
                within: normalizedRoot
            ) else { return nil }
            normalizedWorkingDirectory = validated
        } else {
            normalizedWorkingDirectory = nil
        }
        let normalizedName = visibleName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedName.map({
            $0.utf8.count <= UniConnectLocalWindowRecord.maximumVisibleNameUTF8Bytes
                && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }) ?? true else { return nil }
        self.visibleName = normalizedName?.isEmpty == false
            ? normalizedName!
            : launchTarget.displayName
        self.boxRoot = normalizedRoot
        self.workingDirectory = normalizedWorkingDirectory
        self.launchTarget = launchTarget
    }

    /// Input queued after the login shell appears; `nil` means a plain terminal.
    var startupInput: String? {
        launchTarget.startupCommand(
            boxRoot: boxRoot,
            workingDirectory: workingDirectory
        ).map { $0 + "\n" }
    }
}
