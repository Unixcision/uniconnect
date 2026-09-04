import Darwin
import Foundation
import Testing
@testable import UniConnectClaudeBridge

@Suite("Claude bridge loopback listener")
struct ClaudeBridgeLoopbackListenerTests {
    private enum TestError: Error {
        case socket
        case oversizedResponse
    }

    @Test("Accepts one bounded frame over IPv4 loopback")
    func roundTrip() async throws {
        let listener = try ClaudeBridgeLoopbackListener()
        await listener.start { frame in
            #expect(frame == Data(#"{"message":"fixture"}"#.utf8))
            return Data(#"{"accepted":true}"#.utf8)
        }
        defer { Task { await listener.stop() } }

        let response = try await Task.detached {
            try Self.exchange(port: listener.port, frame: Data(#"{"message":"fixture"}"#.utf8))
        }.value

        #expect(response == Data(#"{"accepted":true}"#.utf8))
        await listener.stop()
    }

    private static func exchange(port: UInt16, frame: Data) throws -> Data {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw TestError.socket }
        defer { Darwin.close(descriptor) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard result == 0 else { throw TestError.socket }

        var request = frame
        request.append(0x0A)
        try request.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.send(descriptor, base.advanced(by: sent), bytes.count - sent, 0)
                guard count > 0 else { throw TestError.socket }
                sent += count
            }
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while response.count <= 4 * 1_024 {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            guard count > 0 else { throw TestError.socket }
            if let newline = buffer[..<count].firstIndex(of: 0x0A) {
                response.append(contentsOf: buffer[..<newline])
                return response
            }
            response.append(contentsOf: buffer[..<count])
        }
        throw TestError.oversizedResponse
    }
}
