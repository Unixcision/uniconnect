import Foundation

/// A stateless parser that proves Claude versions and update outcomes from captured text.
public struct ClaudeUpdateOutputParser: Sendable {
    /// Creates a stateless output parser.
    public init() {}

    /// Extracts the first dotted version from `claude --version` output.
    ///
    /// The parser accepts `major.minor` and `major.minor.patch`, an optional leading `v`, and an
    /// optional hyphenated prerelease. It does not infer a version from update prose alone.
    ///
    /// - Parameter output: Sanitized standard output or standard error from `claude --version`.
    /// - Returns: A normalized version, or `nil` when no dotted numeric version is present.
    public func parseVersion(_ output: String) -> ClaudeVersion? {
        for rawToken in output.split(whereSeparator: { $0.isWhitespace }) {
            guard let firstDigit = rawToken.firstIndex(where: { $0.isNumber }) else { continue }
            let candidate = rawToken[firstDigit...].prefix { character in
                character.isNumber || character.isLetter || character == "." || character == "-"
            }
            guard !candidate.isEmpty else { continue }

            let versionAndPrerelease = candidate.split(separator: "-", maxSplits: 1)
            let numericParts = versionAndPrerelease[0].split(separator: ".", omittingEmptySubsequences: false)
            guard numericParts.count == 2 || numericParts.count == 3 else { continue }
            guard let major = UInt(numericParts[0]), let minor = UInt(numericParts[1]) else {
                continue
            }
            let patch: UInt
            if numericParts.count == 3 {
                guard let parsedPatch = UInt(numericParts[2]) else { continue }
                patch = parsedPatch
            } else {
                patch = 0
            }

            let prerelease = versionAndPrerelease.count == 2
                ? String(versionAndPrerelease[1])
                : nil
            return ClaudeVersion(major: major, minor: minor, patch: patch, prerelease: prerelease)
        }
        return nil
    }

    /// Evaluates whether an update is verifiably updated, already current, or failed.
    ///
    /// A zero exit status is necessary but not sufficient. A higher after-version proves an
    /// update. An equal version proves an already-current installation only when recognized output
    /// explicitly says so. Missing or lower versions and ambiguous success prose fail closed.
    ///
    /// - Parameters:
    ///   - command: Captured output and process status from the controlled update command.
    ///   - before: The version read before any session exits.
    ///   - after: The version read after the update command.
    /// - Returns: A deterministic installation-level assessment.
    public func assess(
        command: ClaudeUpdateCommandResult,
        before: ClaudeVersion?,
        after: ClaudeVersion?
    ) -> ClaudeBinaryUpdateAssessment {
        if command.didTimeOut {
            return ClaudeBinaryUpdateAssessment(status: .failed, issue: .updateTimedOut)
        }
        guard command.exitCode == 0 else {
            return ClaudeBinaryUpdateAssessment(status: .failed, issue: .updateCommandFailed)
        }
        guard let before, let after, after >= before else {
            return ClaudeBinaryUpdateAssessment(status: .failed, issue: .updateUnverifiable)
        }
        if after > before {
            return ClaudeBinaryUpdateAssessment(status: .updated)
        }

        let combinedOutput = "\(command.standardOutput)\n\(command.standardError)".lowercased()
        guard explicitlyReportsCurrentVersion(combinedOutput) else {
            return ClaudeBinaryUpdateAssessment(status: .failed, issue: .updateUnverifiable)
        }
        return ClaudeBinaryUpdateAssessment(status: .alreadyUpdated)
    }

    private func explicitlyReportsCurrentVersion(_ output: String) -> Bool {
        let phrases = [
            "already up to date",
            "already up-to-date",
            "is up to date",
            "is up-to-date",
            "latest version",
            "no update available",
            "no updates available",
        ]
        return phrases.contains(where: output.contains)
    }
}
