import Darwin
import Foundation
import Testing
@testable import UniConnectClaudeBridge

@Suite("Claude bridge loopback listener")
struct ClaudeBridgeLoopbackListenerTests {
    private enum TestError: Error {
        case socket(operation: String, code: Int32)
        case closedBeforeResponse
        case oversizedResponse
    }

    @Test("Accepts one bounded frame over IPv4 loopback")
    func roundTrip() async throws {
        let listener = try ClaudeBridgeLoopbackListener()
        await listener.start { frame in
            #expect(frame == Data(#"{"message":"fixture"}"#.utf8))
            return Data(#"{"accepted":true}"#.utf8)
        }
        let response: Data
        do {
            response = try await withCheckedThrowingContinuation { continuation in
                // Blocking socket I/O must not occupy a cooperative executor worker
                // while the listener needs that same executor to deliver its response.
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try Self.exchange(
                            port: listener.port,
                            frame: Data(#"{"message":"fixture"}"#.utf8)
                        )
                    })
                }
            }
        } catch {
            await listener.stop()
            throw error
        }
        await listener.stop()
        #expect(response == Data(#"{"accepted":true}"#.utf8))
    }

    private static func exchange(port: UInt16, frame: Data) throws -> Data {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw TestError.socket(operation: "socket", code: errno) }
        defer { Darwin.close(descriptor) }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw TestError.socket(operation: "fcntl(FD_CLOEXEC)", code: errno)
        }

        var noSignal: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw TestError.socket(operation: "setsockopt(SO_NOSIGPIPE)", code: errno)
        }
        // Keep the original bound so moving the fixture off the cooperative executor
        // is verified independently of any relaxation in the response deadline.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
            guard setsockopt(
                descriptor,
                SOL_SOCKET,
                option,
                &timeout,
                socklen_t(MemoryLayout<timeval>.size)
            ) == 0 else {
                throw TestError.socket(operation: "setsockopt(\(option))", code: errno)
            }
        }
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
        guard result == 0 else { throw TestError.socket(operation: "connect", code: errno) }

        var request = frame
        request.append(0x0A)
        try request.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.send(descriptor, base.advanced(by: sent), bytes.count - sent, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw TestError.socket(operation: "send", code: errno) }
                sent += count
            }
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while response.count <= 4 * 1_024 {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw TestError.socket(operation: "recv", code: errno) }
            guard count > 0 else { throw TestError.closedBeforeResponse }
            if let newline = buffer[..<count].firstIndex(of: 0x0A) {
                response.append(contentsOf: buffer[..<newline])
                return response
            }
            response.append(contentsOf: buffer[..<count])
        }
        throw TestError.oversizedResponse
    }
}
