import Foundation

/// Tells whether a server's SSH port accepts a TCP connection, without logging in.
protocol UniConnectSSHEndpointProbing: Sendable {
    /// `true` when `host:port` accepted a TCP connection before the probe's timeout.
    func answers(host: String, port: Int) async -> Bool
}
