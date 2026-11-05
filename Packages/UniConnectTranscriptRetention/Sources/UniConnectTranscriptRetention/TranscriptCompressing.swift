public import Foundation

/// The gzip operations a retention pass needs, as a seam for tests.
public protocol TranscriptCompressing: Sendable {
    /// Appends `source`, gzip-compressed, to `destination` as a new gzip member, creating it if
    /// needed. Decompressing the result yields what `destination` held, then `source`.
    /// - Returns: whether it succeeded.
    func append(_ source: URL, to destination: URL) async -> Bool

    /// Whether `archive` is a complete, valid gzip file.
    func verify(_ archive: URL) async -> Bool
}
