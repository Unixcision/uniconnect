import Foundation

/// Enforces that local-agent commands can run only inside an available trusted box folder.
enum UniConnectLocalBoxRootPolicy {
    static func allowsAutomaticResume(
        settingEnabled: Bool,
        agentWasRunningAtQuit: Bool,
        boxRootIsAvailable: Bool
    ) -> Bool {
        settingEnabled && agentWasRunningAtQuit && boxRootIsAvailable
    }

    static func isAvailableDirectory(
        _ root: String,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let normalized = UniConnectLocalWindowRecord.validatedBoxRoot(root) else {
            return false
        }
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: normalized, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Chooses the saved cwd when it still exists, otherwise the existing trusted root.
    static func terminalWorkingDirectory(
        savedWorkingDirectory: String,
        boxRoot: String,
        fileManager: FileManager = .default
    ) -> String? {
        guard let normalizedRoot = UniConnectLocalWindowRecord.validatedBoxRoot(boxRoot),
              let normalizedWorkingDirectory = UniConnectLocalWindowRecord.validatedWorkingDirectory(
                  savedWorkingDirectory,
                  within: normalizedRoot
              ) else {
            return nil
        }
        if isAvailableDirectory(normalizedWorkingDirectory, fileManager: fileManager) {
            return normalizedWorkingDirectory
        }
        // Runtime callers separately handle a missing root (usually by prompting for
        // reassignment). Keeping the validated cwd here preserves deterministic plans
        // and avoids treating an unavailable root as an available fallback.
        return isAvailableDirectory(normalizedRoot, fileManager: fileManager)
            ? normalizedRoot
            : normalizedWorkingDirectory
    }

    /// Requires `cd` to succeed before the supplied command can run.
    static func commandRequiringAvailableRoot(
        _ command: String,
        root: String
    ) -> String? {
        guard let normalized = UniConnectLocalWindowRecord.validatedBoxRoot(root) else {
            return nil
        }
        return "cd -- \(TerminalStartupShellQuoting.singleQuoted(normalized)) && \(command)"
    }

    /// Requires a window cwd to stay inside its immutable trusted box boundary.
    static func commandRequiringWorkingDirectory(
        _ command: String,
        workingDirectory: String,
        boxRoot: String
    ) -> String? {
        guard let normalized = UniConnectLocalWindowRecord.validatedWorkingDirectory(
            workingDirectory,
            within: boxRoot
        ) else {
            return nil
        }
        return "cd -- \(TerminalStartupShellQuoting.singleQuoted(normalized)) && \(command)"
    }

    /// Chooses an existing directory for a shell-only recovery surface without changing
    /// the persisted missing root. Agent commands remain blocked until explicit reassignment.
    static func safeShellFallbackDirectory(
        currentDirectory: String?,
        missingRoot: String,
        fileManager: FileManager = .default
    ) -> String {
        let missing = UniConnectLocalWindowRecord.validatedBoxRoot(missingRoot)
        let candidates: [String?] = [
            currentDirectory,
            fileManager.homeDirectoryForCurrentUser.path,
            "/",
        ]
        for candidate in candidates {
            guard let candidate,
                  let normalized = UniConnectLocalWindowRecord.validatedBoxRoot(candidate),
                  normalized != missing,
                  isAvailableDirectory(normalized, fileManager: fileManager) else {
                continue
            }
            return normalized
        }
        return "/"
    }
}
