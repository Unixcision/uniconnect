import Foundation

/// What `agent.update` may change when it reopens a Claude: its model and its effort.
///
/// A key that is absent means «igual que estaba»: the agent comes back with whatever it ran with.
/// Both values are validated here, once, because they end up typed into a shell
/// (`contracts/relaunch-v1/LEEME.md`, «Actualizar Claude», 09-11-2026).
///
/// ```swift
/// let options = try RelaunchUpdateOptions(model: "fable[1m]", effort: "medium")
/// options.arguments  // ["--model", "fable[1m]", "--effort", "medium"]
/// ```
public struct RelaunchUpdateOptions: Sendable, Equatable, Hashable {
    /// The model alias or id to reopen with, or `nil` to keep the one the conversation had.
    public let model: String?
    /// The effort to reopen with, or `nil` to keep the one it had.
    public let effort: RelaunchEffort?

    /// No change at all: the same model and effort.
    public static let unchanged = RelaunchUpdateOptions(validModel: nil, effort: nil)

    /// Validates a requested model and effort.
    ///
    /// - Parameters:
    ///   - model: A Claude alias or id matching `^[a-z0-9.\-\[\]]{2,40}$`, or `nil`.
    ///   - effort: `low`, `medium`, `high`, `xhigh` or `max`, or `nil`.
    /// - Throws: ``RelaunchError/invalidOptions`` when either value is malformed.
    public init(model: String?, effort: String?) throws(RelaunchError) {
        if let model {
            guard model.range(of: #"^[a-z0-9.\-\[\]]{2,40}$"#, options: .regularExpression) != nil else {
                throw .invalidOptions
            }
        }
        var parsedEffort: RelaunchEffort?
        if let effort {
            guard let value = RelaunchEffort(rawValue: effort) else { throw .invalidOptions }
            parsedEffort = value
        }
        self.init(validModel: model, effort: parsedEffort)
    }

    private init(validModel: String?, effort: RelaunchEffort?) {
        self.model = validModel
        self.effort = effort
    }

    /// Reads the `options` object of a plan request for `verb`.
    ///
    /// - Parameters:
    ///   - object: The decoded `options` value, or `nil` when the request has none.
    ///   - verb: The plan's verb.
    /// - Returns: The options; ``unchanged`` when there are none.
    /// - Throws: ``RelaunchError/invalidOptions`` for options on any verb but
    ///   ``RelaunchVerb/agentUpdate``, for a value that is not an object of strings, for an
    ///   unknown key, or for a malformed model or effort.
    public static func parse(_ object: Any?, verb: RelaunchVerb) throws(RelaunchError) -> RelaunchUpdateOptions {
        guard let object, !(object is NSNull) else { return .unchanged }
        guard verb == .agentUpdate, let fields = object as? [String: Any] else { throw .invalidOptions }
        guard Set(fields.keys).isSubset(of: ["model", "effort"]) else { throw .invalidOptions }
        func string(_ key: String) throws(RelaunchError) -> String? {
            guard let value = fields[key], !(value is NSNull) else { return nil }
            guard let text = value as? String else { throw .invalidOptions }
            return text
        }
        return try RelaunchUpdateOptions(model: string("model"), effort: string("effort"))
    }

    /// Whether neither the model nor the effort changes.
    public var isUnchanged: Bool { model == nil && effort == nil }

    /// The options as they travel in a plan response (`{"model": …, "effort": …}`).
    public var json: [String: String] {
        var fields: [String: String] = [:]
        if let model { fields["model"] = model }
        if let effort { fields["effort"] = effort.rawValue }
        return fields
    }

    /// The Claude arguments that apply these options: `--model <m>` and/or `--effort <e>`.
    public var arguments: [String] {
        var result: [String] = []
        if let model { result += ["--model", model] }
        if let effort { result += ["--effort", effort.rawValue] }
        return result
    }
}
