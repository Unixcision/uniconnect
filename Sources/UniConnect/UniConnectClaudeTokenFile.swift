import Darwin
import Foundation

/// A Claude token kept in a file, the way `claude setup-token` users keep it (`~/.claude-kin-token`).
///
/// A Claude started with `CLAUDE_CODE_OAUTH_TOKEN` runs on that token's account, not on the login
/// saved in its configuration folder. To resume it on the same account, UniConnect remembers which
/// of the user's token files holds that token (the path, never the token) and resumes with
/// `CLAUDE_CODE_OAUTH_TOKEN="$(cat -- '<path>')" claude …`, which reads the file at launch.
///
/// ```swift
/// let tokens = UniConnectClaudeTokenFile()
/// tokens.observation(environment: liveClaude.environment) // .file("/Users/dani/.claude-kin-token")
/// UniConnectClaudeTokenFile.shellAssignment(path: "/Users/dani/.claude-kin-token")
/// // CLAUDE_CODE_OAUTH_TOKEN="$(cat -- '/Users/dani/.claude-kin-token')"
/// ```
struct UniConnectClaudeTokenFile: Sendable {
    /// The variable Claude Code reads its token from.
    static let environmentKey = "CLAUDE_CODE_OAUTH_TOKEN"
    /// A token file is a few hundred bytes; anything larger is not one.
    static let maximumFileBytes = 4_096
    static let maximumPathUTF8Bytes = 4 * 1_024

    /// What one live Claude says about its token.
    enum Observation: Equatable, Sendable {
        /// No token in its environment: it uses the login of its configuration folder.
        case noToken
        /// Its token is the one in this file.
        case file(String)
        /// A token that no file of the user holds. It cannot be reproduced, so what is saved stays.
        case unmatched
    }

    private let homeDirectory: URL
    private let userID: uid_t

    /// - Parameters:
    ///   - homeDirectory: Where the token files live; tests pass a temporary folder.
    ///   - userID: The owner a token file must have; the current user by default.
    init(
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        userID: uid_t = getuid()
    ) {
        self.homeDirectory = homeDirectory
        self.userID = userID
    }

    /// What a live Claude's environment says about its token.
    func observation(environment: [String: String]) -> Observation {
        guard let token = environment[Self.environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return .noToken }
        return file(holding: token).map(Observation.file) ?? .unmatched
    }

    /// The user's token file that holds exactly `token`.
    ///
    /// Only a regular file directly in the home folder counts, named `.claude…token…` or
    /// `claude…token…`, owned by the user, writable by no one else and of at most 4 KB. Symbolic
    /// links are not followed. Nothing read is kept or logged.
    func file(holding token: String) -> String? {
        let wanted = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty,
              let names = try? FileManager.default.contentsOfDirectory(atPath: homeDirectory.path) else { return nil }
        for name in names.sorted() where Self.isCandidateName(name) {
            let path = homeDirectory.appendingPathComponent(name, isDirectory: false).path
            guard Self.validatedPath(path) != nil, isPrivateRegularFile(atPath: path),
                  let data = FileManager.default.contents(atPath: path), data.count <= Self.maximumFileBytes,
                  let content = String(data: data, encoding: .utf8),
                  content.trimmingCharacters(in: .whitespacesAndNewlines) == wanted else { continue }
            return path
        }
        return nil
    }

    /// Whether a file name looks like a Claude token file.
    static func isCandidateName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return (lowered.hasPrefix(".claude") || lowered.hasPrefix("claude")) && lowered.contains("token")
    }

    /// A saved path that may be used: absolute, without control characters, of at most 4 KB.
    static func validatedPath(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/"), path.utf8.count <= maximumPathUTF8Bytes,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return path
    }

    /// The shell assignment that reads the token at launch, `KEY="$(cat -- '<path>')"`, or `nil`
    /// for a path that may not be used.
    static func shellAssignment(path: String) -> String? {
        guard let path = validatedPath(path) else { return nil }
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "\(environmentKey)=\"$(cat -- \(quoted))\""
    }

    /// A regular file (never a link) of this user that only the user can write.
    private func isPrivateRegularFile(atPath path: String) -> Bool {
        var status = stat()
        guard lstat(path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == userID, (status.st_mode & (S_IWGRP | S_IWOTH)) == 0,
              status.st_size <= off_t(Self.maximumFileBytes) else { return false }
        return true
    }
}
