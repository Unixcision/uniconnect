/// A comparable Claude Code version with optional prerelease metadata.
public struct ClaudeVersion: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    /// The major version component.
    public let major: UInt

    /// The minor version component.
    public let minor: UInt

    /// The patch version component.
    public let patch: UInt

    /// Optional prerelease text without the leading hyphen.
    public let prerelease: String?

    /// Creates a Claude version.
    ///
    /// - Parameters:
    ///   - major: The nonnegative major component.
    ///   - minor: The nonnegative minor component.
    ///   - patch: The nonnegative patch component.
    ///   - prerelease: Optional prerelease text without a leading hyphen.
    public init(major: UInt, minor: UInt, patch: UInt, prerelease: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// A normalized dotted version string.
    public var description: String {
        let base = "\(major).\(minor).\(patch)"
        guard let prerelease, !prerelease.isEmpty else { return base }
        return "\(base)-\(prerelease)"
    }

    /// Orders versions by numeric components and then prerelease stability.
    ///
    /// Stable versions sort after prereleases with the same numeric components. Prerelease text is
    /// compared lexicographically to preserve ordering consistency with synthesized equality.
    ///
    /// - Parameters:
    ///   - lhs: The first version.
    ///   - rhs: The second version.
    /// - Returns: `true` when `lhs` precedes `rhs`.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case let (.some(left), .some(right)):
            return left < right
        }
    }
}
