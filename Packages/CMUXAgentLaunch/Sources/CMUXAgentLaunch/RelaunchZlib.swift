import Foundation

/// zlib streams (RFC 1950) around Foundation's raw DEFLATE, which is what Python's
/// `zlib.decompress` expects: a two-byte header, the deflated data, and an Adler-32 trailer.
public struct RelaunchZlib: Sendable {
    /// Creates the codec.
    public init() {}

    /// Compresses `data` into a zlib stream.
    ///
    /// - Parameter data: The bytes to compress.
    /// - Returns: Header `78 DA`, raw DEFLATE, big-endian Adler-32 of `data`.
    public func compress(_ data: Data) -> Data {
        let deflated = ((try? (data as NSData).compressed(using: .zlib)) as Data?) ?? Data()
        var stream = Data([0x78, 0xDA])
        stream.append(deflated)
        let checksum = adler32(data)
        stream.append(contentsOf: [UInt8(checksum >> 24), UInt8((checksum >> 16) & 0xFF),
                                   UInt8((checksum >> 8) & 0xFF), UInt8(checksum & 0xFF)])
        return stream
    }

    /// Inflates a zlib stream produced by ``compress(_:)`` or by Python's `zlib.compress`.
    ///
    /// - Parameter stream: A zlib stream.
    /// - Returns: The original bytes, or `nil` when the header or checksum does not match.
    public func decompress(_ stream: Data) -> Data? {
        guard stream.count >= 6 else { return nil }
        let bytes = [UInt8](stream)
        guard bytes[0] & 0x0F == 8, (UInt16(bytes[0]) << 8 | UInt16(bytes[1])) % 31 == 0 else { return nil }
        let body = Data(bytes[2..<(bytes.count - 4)])
        guard let inflated = try? (body as NSData).decompressed(using: .zlib) as Data else { return nil }
        let trailer = bytes[(bytes.count - 4)...].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return adler32(inflated) == trailer ? inflated : nil
    }

    private func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        return b << 16 | a
    }
}
