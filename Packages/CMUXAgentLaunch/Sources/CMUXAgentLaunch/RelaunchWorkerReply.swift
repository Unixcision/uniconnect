import Foundation

/// The single `UC_RELAUNCH_V1 {json}` line the Linux worker prints, parsed tolerantly.
///
/// A login shell may print banners around it; only that line counts, and only when there is
/// exactly one and it is at most 64 KiB. Unknown fields are ignored and every field is optional,
/// so a newer worker (monitors, drafts, `context_tokens`, `updates`…) keeps being understood.
public struct RelaunchWorkerReply: Sendable, Equatable {
    /// The reply's JSON object, re-encoded.
    public let object: Data
    /// `error`: the worker refused the call with this cause.
    public let error: String?

    /// Parses a worker's standard output.
    ///
    /// - Parameter output: Everything the remote command printed.
    /// - Returns: `nil` when there is not exactly one well-formed reply line.
    public init?(output: Data) {
        let text = String(decoding: output, as: UTF8.self)
        let prefix = "UC_RELAUNCH_V1 "
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }
            .filter { $0.hasPrefix(prefix) }
        guard lines.count == 1 else { return nil }
        let body = lines[0].dropFirst(prefix.count)
        guard body.utf8.count <= 65_536,
              let value = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        object = data
        error = value["error"] as? String
    }

    /// The decoded object.
    public var fields: [String: Any] {
        (try? JSONSerialization.jsonObject(with: object) as? [String: Any]) ?? [:]
    }

    /// The cause a refusal carries, as a known cause when it is one.
    public var errorCause: RelaunchCause? {
        error.flatMap(RelaunchCause.init(rawValue:))
    }
}
