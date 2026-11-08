import Foundation

/// The user a new window's agent runs as (`contracts/run-as-v1`), never with its password.
///
/// It travels from the phone or the desktop sheet, is saved with the window so relaunch and
/// recovery can switch user again, and only describes the switch: the password lives in
/// ``UniConnectRunAsPasswordStore``.
///
/// ```json
/// {"mode": "root", "method": "sudo", "user": null}
/// ```
struct UniConnectRunAs: Codable, Equatable, Hashable, Sendable {
    /// Whose account the agent ends up in.
    enum Mode: String, Codable, Sendable {
        /// The account the box connects with; no switch.
        case current
        /// `root`.
        case root
        /// The account in ``UniConnectRunAs/user``.
        case user
    }

    /// How the switch is made.
    enum Method: String, Codable, Sendable {
        /// `sudo -i` / `sudo -iu <user>`, with the password of the connected account.
        case sudo
        /// `su -` / `su - <user>`, with the password of the target account.
        case su
    }

    let mode: Mode
    let method: Method
    /// The target account for ``Mode/user``; `nil` for the other modes.
    let user: String?

    /// - Returns: `nil` when ``Mode/user`` comes without a valid account name.
    init?(mode: Mode, method: Method = .sudo, user: String? = nil) {
        switch mode {
        case .user:
            guard let user, Self.isValidUser(user) else { return nil }
            self.user = user
        case .current, .root:
            self.user = nil
        }
        self.mode = mode
        self.method = method
    }

    /// Reads the `run_as` object of a create request; `nil` when it is malformed.
    init?(wire: [String: Any]) {
        guard let rawMode = wire["mode"] as? String, let mode = Mode(rawValue: rawMode) else { return nil }
        let method: Method
        switch wire["method"] {
        case nil, is NSNull:
            method = .sudo
        case let raw as String:
            guard let parsed = Method(rawValue: raw) else { return nil }
            method = parsed
        default:
            return nil
        }
        let user: String?
        switch wire["user"] {
        case nil, is NSNull:
            user = nil
        case let raw as String:
            user = raw.trimmingCharacters(in: .whitespaces).isEmpty ? nil : raw
        default:
            return nil
        }
        self.init(mode: mode, method: method, user: user)
    }

    /// The account the agent must run as, or `nil` for the connected one.
    var targetUser: String? {
        switch mode {
        case .current: return nil
        case .root: return "root"
        case .user: return user
        }
    }

    /// An account name that can never be shell syntax: letters, digits, `_`, `.`, `-`.
    static func isValidUser(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first, value.utf8.count <= 32,
              first != "-", first != "." else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "_.-".unicodeScalars.contains(scalar))
        }
    }
}
