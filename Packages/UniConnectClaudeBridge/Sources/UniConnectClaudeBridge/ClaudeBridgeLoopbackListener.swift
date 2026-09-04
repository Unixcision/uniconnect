import Darwin
import Foundation

/// A small newline-delimited JSON listener bound exclusively to `127.0.0.1`.
///
/// SSH exposes this listener remotely only through each connection's reverse
/// forward. The listener performs no polling and uses a bounded frame and read timeout.
public actor ClaudeBridgeLoopbackListener {
    private final class ClientLimiter: @unchecked Sendable {
        private let lock = NSLock()
        private let maximum: Int
        private var active = 0

        init(maximum: Int) {
            self.maximum = maximum
        }

        func tryAcquire() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard active < maximum else { return false }
            active += 1
            return true
        }

        func release() {
            lock.lock()
            active = max(0, active - 1)
            lock.unlock()
        }
    }

    /// The ephemeral local port selected synchronously during construction.
    public nonisolated let port: UInt16

    private let listenerFileDescriptor: Int32
    private var acceptTask: Task<Void, Never>?
    private var stopped = false

    /// Creates and binds a loopback-only listener without starting its accept loop.
    ///
    /// - Throws: ``ClaudeBridgeListenerError`` when the socket cannot be prepared.
    public init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ClaudeBridgeListenerError.socketCreation(errno)
        }

        var reuseAddress: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuseAddress,
            socklen_t(MemoryLayout<Int32>.size)
        )
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw ClaudeBridgeListenerError.bind(code)
        }
        guard Darwin.listen(descriptor, 16) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw ClaudeBridgeListenerError.listen(code)
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let addressResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(descriptor, socketAddress, &length)
            }
        }
        guard addressResult == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw ClaudeBridgeListenerError.address(code)
        }

        self.listenerFileDescriptor = descriptor
        self.port = UInt16(bigEndian: boundAddress.sin_port)
    }

    /// Starts accepting bounded frames exactly once.
    ///
    /// - Parameter handler: Async frame handler that returns one bounded JSON response.
    public func start(
        handler: @escaping @Sendable (Data) async -> Data
    ) {
        guard acceptTask == nil, !stopped else { return }
        let descriptor = listenerFileDescriptor
        acceptTask = Task.detached(priority: .utility) {
            await Self.runAcceptLoop(listenerFileDescriptor: descriptor, handler: handler)
        }
    }

    /// Stops accepting immediately by closing the listener socket.
    public func stop() {
        guard !stopped else { return }
        stopped = true
        acceptTask?.cancel()
        acceptTask = nil
        _ = shutdown(listenerFileDescriptor, SHUT_RDWR)
        Darwin.close(listenerFileDescriptor)
    }

    private nonisolated static func runAcceptLoop(
        listenerFileDescriptor: Int32,
        handler: @escaping @Sendable (Data) async -> Data
    ) async {
        let clientLimiter = ClientLimiter(maximum: 32)
        while !Task.isCancelled {
            var peer = sockaddr_in()
            var peerLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &peer) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.accept(listenerFileDescriptor, socketAddress, &peerLength)
                }
            }
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            guard peer.sin_family == sa_family_t(AF_INET),
                  peer.sin_addr.s_addr == inet_addr("127.0.0.1") else {
                Darwin.close(client)
                continue
            }
            guard clientLimiter.tryAcquire() else {
                Darwin.close(client)
                continue
            }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            Task.detached(priority: .utility) {
                defer { clientLimiter.release() }
                await handleClient(client, handler: handler)
            }
        }
    }

    private nonisolated static func handleClient(
        _ client: Int32,
        handler: @escaping @Sendable (Data) async -> Data
    ) async {
        defer {
            _ = shutdown(client, SHUT_RDWR)
            Darwin.close(client)
        }

        var noSignal: Int32 = 1
        _ = setsockopt(
            client,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(
            client,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )

        guard let frame = readFrame(from: client) else { return }
        var response = await handler(frame)
        guard response.count <= 4 * 1_024 else { return }
        response.append(0x0A)
        response.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.send(
                    client,
                    baseAddress.advanced(by: sent),
                    bytes.count - sent,
                    0
                )
                if count <= 0 { return }
                sent += count
            }
        }
    }

    private nonisolated static func readFrame(from descriptor: Int32) -> Data? {
        let maximumFrameBytes = 16 * 1_024
        var result = Data()
        result.reserveCapacity(1_024)
        var buffer = [UInt8](repeating: 0, count: 1_024)

        while result.count <= maximumFrameBytes {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            guard count > 0 else { return nil }
            if let newline = buffer[..<count].firstIndex(of: 0x0A) {
                guard result.count + newline <= maximumFrameBytes else { return nil }
                result.append(contentsOf: buffer[..<newline])
                return result.isEmpty ? nil : result
            }
            guard result.count + count <= maximumFrameBytes else { return nil }
            result.append(contentsOf: buffer[..<count])
        }
        return nil
    }
}
