import Foundation

/// Validates local folders and requires an explicit successful `cd` before agent commands run.
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

    /// An independent window folder remains usable when the workspace default disappears.
    static func hasAvailableLaunchDirectory(
        savedWorkingDirectory: String,
        boxRoot: String,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let workingDirectory = UniConnectLocalWindowRecord.validatedWorkingDirectory(
            savedWorkingDirectory,
            within: boxRoot
        ) else { return false }
        return isAvailableDirectory(workingDirectory, fileManager: fileManager)
            || isAvailableDirectory(boxRoot, fileManager: fileManager)
    }

    /// Chooses the independent saved cwd when it exists, otherwise the workspace default.
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

    /// Requires a valid independent window folder without changing the workspace default.
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
