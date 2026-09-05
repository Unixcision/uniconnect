import CMUXMobileCore
import Network

/// Converts only observed numeric transport endpoints into approval keys.
enum UniConnectMobilePeerEndpoint {
    static func tailnetAddress(from endpoint: NWEndpoint?) -> String? {
        guard case let .hostPort(host, _)? = endpoint else { return nil }
        switch host {
        case let .ipv4(address): return TailnetPeerAddress(ipv4Bytes: Array(address.rawValue))?.rawValue
        case let .ipv6(address): return TailnetPeerAddress(ipv6Bytes: Array(address.rawValue))?.rawValue
        default: return nil
        }
    }
}
