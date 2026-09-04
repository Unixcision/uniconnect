import Foundation

/// Validates the Sparkle appcast URL embedded in the host application's `Info.plist`.
///
/// UniConnect source and local-development builds intentionally ship without an active feed.
/// Only the exact Unixcision stable and nightly HTTPS appcasts are accepted by default, so a
/// missing, placeholder, malformed, or inherited upstream value leaves Sparkle disabled.
///
/// ```swift
/// let resolution = UpdateFeedResolver().resolve(
///     infoFeedURL: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
/// )
/// if let feedURL = resolution.url {
///     // The signed release may start Sparkle with this validated URL.
/// }
/// ```
public struct UpdateFeedResolver: Sendable {
    /// The result of validating a build-time appcast setting.
    public struct Resolution: Equatable, Sendable {
        /// The validated feed URL, or `nil` when software updates must remain disabled.
        public let url: String?
        /// Whether ``url`` is the Unixcision nightly appcast.
        public let isNightly: Bool
        /// Whether a non-placeholder URL was present but rejected by the allowlist.
        public let rejectedConfiguredURL: Bool

        /// Whether this resolution authorizes Sparkle to start.
        public var isEnabled: Bool { url != nil }

        /// Creates a feed resolution.
        ///
        /// - Parameters:
        ///   - url: A validated appcast URL, or `nil` to disable updates.
        ///   - isNightly: Whether the URL belongs to the nightly channel.
        ///   - rejectedConfiguredURL: Whether an explicitly configured URL failed validation.
        public init(url: String?, isNightly: Bool, rejectedConfiguredURL: Bool) {
            self.url = url
            self.isNightly = isNightly
            self.rejectedConfiguredURL = rejectedConfiguredURL
        }
    }

    /// The stable appcast injected into signed UniConnect releases.
    public static let stableFeedURL =
        "https://github.com/Unixcision/uniconnect/releases/latest/download/appcast.xml"

    /// The appcast injected into signed UniConnect nightly builds.
    public static let nightlyFeedURL =
        "https://github.com/Unixcision/uniconnect/releases/download/nightly/appcast.xml"

    /// Exact feed URLs accepted by this resolver.
    public let allowedFeedURLs: Set<String>

    /// Creates a resolver with an explicit URL allowlist.
    ///
    /// - Parameter allowedFeedURLs: Exact HTTPS appcast URLs that may enable Sparkle. Defaults
    ///   to the Unixcision stable and nightly release feeds.
    public init(allowedFeedURLs: Set<String> = [Self.stableFeedURL, Self.nightlyFeedURL]) {
        self.allowedFeedURLs = allowedFeedURLs
    }

    /// Validates the appcast value embedded in the application bundle.
    ///
    /// Empty values and the source-build `about:blank` placeholder intentionally resolve to a
    /// disabled updater. Every other value must exactly match the allowlist.
    ///
    /// - Parameter infoFeedURL: The build's `SUFeedURL` value, if present.
    /// - Returns: A resolution containing a URL only when Sparkle may safely start.
    public func resolve(infoFeedURL: String?) -> Resolution {
        let candidate = infoFeedURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !candidate.isEmpty, candidate.lowercased() != "about:blank" else {
            return Resolution(url: nil, isNightly: false, rejectedConfiguredURL: false)
        }

        guard allowedFeedURLs.contains(candidate),
              let components = URLComponents(string: candidate),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "github.com",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil else {
            return Resolution(url: nil, isNightly: false, rejectedConfiguredURL: true)
        }

        return Resolution(
            url: candidate,
            isNightly: candidate == Self.nightlyFeedURL,
            rejectedConfiguredURL: false
        )
    }
}
