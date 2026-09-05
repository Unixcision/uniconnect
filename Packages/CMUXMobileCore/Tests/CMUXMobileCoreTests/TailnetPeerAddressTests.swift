import Testing
@testable import CMUXMobileCore

@Suite("Observed Tailscale address normalization")
struct TailnetPeerAddressTests {
    @Test(arguments: ["100.64.0.0", "100.127.255.255", "100.123.234.20"])
    func acceptsOnlyTheCGNATRange(_ value: String) {
        #expect(TailnetPeerAddress(value)?.rawValue == value)
    }

    @Test(arguments: [
        "", "0.0.0.0", "127.0.0.1", "192.168.1.1", "10.0.0.1",
        "100.63.255.255", "100.128.0.0", "100.64.256.1", "100.064.1.2",
        "100.64.1.2.example.com", "mac.tailnet.ts.net", " 100.64.1.2",
        "::", "::1", "fe80::1", "fd7a:115c:a1e1::1", "::ffff:192.168.1.2",
        "fd7a:115c:a1e0::1%en0", "fd7a:115c:a1e0:::1", "fd7a:115c:a1e0::1::2",
    ])
    func rejectsNonTailnetOrAmbiguousValues(_ value: String) {
        #expect(TailnetPeerAddress(value) == nil)
    }

    @Test func mappedIPv4SharesTheSameApprovalKey() {
        let expected = TailnetPeerAddress("100.64.1.2")
        #expect(TailnetPeerAddress("::ffff:100.64.1.2") == expected)
        #expect(TailnetPeerAddress("0:0:0:0:0:FFFF:6440:0102") == expected)
        #expect(TailnetPeerAddress(ipv6Bytes: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 100, 64, 1, 2]) == expected)
    }

    @Test func equivalentIPv6LiteralsHaveOneKey() {
        let expected = TailnetPeerAddress("fd7a:115c:a1e0::1")
        #expect(expected?.rawValue == "fd7a:115c:a1e0:0:0:0:0:1")
        #expect(TailnetPeerAddress("FD7A:115C:A1E0:0000:0:0:0:0001") == expected)
        #expect(TailnetPeerAddress(ipv6Bytes: [253, 122, 17, 92, 161, 224, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]) == expected)
    }

    @Test func rejectsWrongLengthEndpointBytes() {
        #expect(TailnetPeerAddress(ipv4Bytes: [100, 64, 1]) == nil)
        #expect(TailnetPeerAddress(ipv6Bytes: [253, 122, 17, 92, 161, 224]) == nil)
    }
}
