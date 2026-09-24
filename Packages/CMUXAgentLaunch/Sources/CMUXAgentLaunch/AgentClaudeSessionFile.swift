import Foundation

/// The session file Claude Code keeps per live process in `<config>/sessions/<pid>.json`.
///
/// It is the reliable source of the conversation a Claude process is on: the command line lies
/// after `/clear` or an in-app `/resume`, this file does not. Unknown keys are ignored and every
/// field but `sessionId` is optional, so newer Claude versions keep decoding.
public struct AgentClaudeSessionFile: Sendable, Equatable, Decodable {
    /// The largest file this reader accepts; anything bigger is not a session file.
    public static let maximumSize = 64 * 1024

    /// The conversation id.
    public let sessionId: String
    /// The folder Claude is working in, as Claude reports it.
    public let cwd: String?
    /// `idle`, `busy`, `shell`, `waiting` or whatever a newer version reports.
    public let status: String?
    /// The Claude Code version that wrote the file.
    public let version: String?
    /// The process start time as Claude printed it, used to tell a recycled pid apart.
    public let procStart: String?

    /// Creates a session file value, for tests and fixtures.
    ///
    /// - Parameters:
    ///   - sessionId: The conversation id.
    ///   - cwd: The working folder.
    ///   - status: The reported status.
    ///   - version: The Claude Code version.
    ///   - procStart: The process start time.
    public init(sessionId: String, cwd: String? = nil, status: String? = nil, version: String? = nil, procStart: String? = nil) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.status = status
        self.version = version
        self.procStart = procStart
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, cwd, status, version, procStart
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        // A field that changes type in a newer Claude must not hide the conversation id.
        cwd = try? container.decodeIfPresent(String.self, forKey: .cwd)
        status = try? container.decodeIfPresent(String.self, forKey: .status)
        version = try? container.decodeIfPresent(String.self, forKey: .version)
        procStart = try? container.decodeIfPresent(String.self, forKey: .procStart)
    }

    /// Reads and decodes one session file, refusing anything larger than ``maximumSize``.
    ///
    /// - Parameter url: The `<pid>.json` file.
    /// - Returns: The decoded file, or `nil` when it is missing, too large, or not a session file.
    public static func read(at url: URL) -> AgentClaudeSessionFile? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumSize + 1),
              data.count <= maximumSize,
              let file = try? JSONDecoder().decode(AgentClaudeSessionFile.self, from: data),
              AgentNoPromptPolicy.isValidSessionID(file.sessionId) else { return nil }
        return file
    }
}
