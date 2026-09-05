import Foundation

/// A canonical numeric address in Tailscale's IPv4 or IPv6 address range.
///
/// Range membership is not proof of peer identity. Hosts must obtain this value
/// from the accepted transport endpoint, never from an RPC parameter or a name.
public struct TailnetPeerAddress: Hashable, Sendable {
    /// The canonical numeric address used as the host's local approval key.
    public let rawValue: String

    /// Validates and normalizes a numeric address without performing DNS lookup.
    /// - Parameter rawValue: A literal IPv4, IPv6, or IPv4-mapped IPv6 address.
    public init?(_ rawValue: String) {
        guard !rawValue.isEmpty, rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.contains("%") else { return nil }
        if let bytes = Self.ipv4Bytes(rawValue) {
            self.init(ipv4Bytes: bytes)
            return
        }
        guard let bytes = Self.ipv6Bytes(rawValue) else { return nil }
        self.init(ipv6Bytes: bytes)
    }

    /// Creates an approval key from the four bytes of an observed IPv4 endpoint.
    /// - Parameter ipv4Bytes: Exactly four network-order octets.
    public init?(ipv4Bytes: [UInt8]) {
        guard ipv4Bytes.count == 4, ipv4Bytes[0] == 100,
              (64...127).contains(ipv4Bytes[1]) else { return nil }
        rawValue = ipv4Bytes.map(String.init).joined(separator: ".")
    }

    /// Creates an approval key from a native or IPv4-mapped IPv6 endpoint.
    /// - Parameter ipv6Bytes: Exactly sixteen network-order octets.
    public init?(ipv6Bytes: [UInt8]) {
        guard ipv6Bytes.count == 16 else { return nil }
        if ipv6Bytes.prefix(10).allSatisfy({ $0 == 0 }), ipv6Bytes[10] == 255, ipv6Bytes[11] == 255 {
            self.init(ipv4Bytes: Array(ipv6Bytes.suffix(4)))
            return
        }
        guard Array(ipv6Bytes.prefix(6)) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0] else { return nil }
        let canonical = stride(from: 0, to: 16, by: 2).map { index in
            String(UInt16(ipv6Bytes[index]) << 8 | UInt16(ipv6Bytes[index + 1]), radix: 16)
        }.joined(separator: ":")
        self.init(validatedCanonical: canonical)
    }

    private init(validatedCanonical: String) { rawValue = validatedCanonical }

    private static func ipv4Bytes(_ value: String) -> [UInt8]? {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return nil }
        let octets = components.compactMap { component -> UInt8? in
            guard !component.isEmpty, component.utf8.allSatisfy({ (48...57).contains($0) }),
                  component.count == 1 || component.first != "0" else { return nil }
            return UInt8(component)
        }
        return octets.count == 4 ? octets : nil
    }

    private static func ipv6Bytes(_ original: String) -> [UInt8]? {
        var value = original.lowercased()
        if value.contains(".") {
            guard let separator = value.lastIndex(of: ":"),
                  let tail = ipv4Bytes(String(value[value.index(after: separator)...])) else { return nil }
            value = String(value[...separator])
                + String(UInt16(tail[0]) << 8 | UInt16(tail[1]), radix: 16) + ":"
                + String(UInt16(tail[2]) << 8 | UInt16(tail[3]), radix: 16)
        }
        let halves = value.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        func words(_ half: String) -> [UInt16]? {
            if half.isEmpty { return [] }
            let parts = half.split(separator: ":", omittingEmptySubsequences: false)
            let result = parts.compactMap { part -> UInt16? in
                guard (1...4).contains(part.count), part.utf8.allSatisfy({
                    (48...57).contains($0) || (97...102).contains($0)
                }) else { return nil }
                return UInt16(part, radix: 16)
            }
            return result.count == parts.count ? result : nil
        }
        guard let left = words(halves[0]) else { return nil }
        let result: [UInt16]
        if halves.count == 2 {
            guard let right = words(halves[1]), left.count + right.count < 8 else { return nil }
            result = left + Array(repeating: 0, count: 8 - left.count - right.count) + right
        } else {
            guard left.count == 8 else { return nil }
            result = left
        }
        return result.flatMap { [UInt8($0 >> 8), UInt8($0 & 255)] }
    }
}
