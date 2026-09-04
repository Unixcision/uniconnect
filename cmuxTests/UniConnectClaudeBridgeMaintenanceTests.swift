import CryptoKit
import Foundation
import Testing
import UniConnectClaudeBridge

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct UniConnectClaudeBridgeMaintenanceTests {
    private actor TokenStore: ClaudeBridgeTokenStoring {
        private var tokens: [UUID: (Data, UUID)] = [:]

        func token(for routeID: UUID) async throws -> Data? {
            tokens[routeID]?.0
        }

        func store(token: Data, for routeID: UUID, credentialID: UUID) async throws {
            tokens[routeID] = (token, credentialID)
        }

        func removeToken(for routeID: UUID) async throws {
            tokens.removeValue(forKey: routeID)
        }

        func routeIDs(for credentialID: UUID) async throws -> [UUID] {
            tokens.compactMap { $0.value.1 == credentialID ? $0.key : nil }
        }
    }

    private actor Executor: UniConnectSSHCommandExecuting {
        enum StubError: Error {
            case failed
        }

        private let shouldFail: Bool
        private(set) var invocations: [UniConnectSSHProcessInvocation] = []

        init(shouldFail: Bool = false) {
            self.shouldFail = shouldFail
        }

        func execute(
            _ invocation: UniConnectSSHProcessInvocation,
            timeout: Duration
        ) async throws {
            invocations.append(invocation)
            if shouldFail { throw StubError.failed }
        }

        func lastInvocation() -> UniConnectSSHProcessInvocation? {
            invocations.last
        }
    }

    @Test
    func verifiedCleanupUsesOneShellFreeSSHRequestAndThenForgetsTokens() async throws {
        let routeA = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        let routeB = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
        let credentialID = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
        let tokenStore = TokenStore()
        try await tokenStore.store(
            token: Data(repeating: 0x11, count: 32),
            for: routeA,
            credentialID: credentialID
        )
        try await tokenStore.store(
            token: Data(repeating: 0x22, count: 32),
            for: routeB,
            credentialID: credentialID
        )
        let executor = Executor()
        let service = UniConnectClaudeBridgeMaintenanceService(
            tokenStore: tokenStore,
            commandExecutor: executor,
            installationKey: SymmetricKey(data: Data(repeating: 0x33, count: 32))
        )
        let session = DetectedSSHSession(
            destination: "bridge-test.invalid",
            port: 22,
            identityFile: nil,
            configFile: nil,
            jumpHost: nil,
            controlPath: nil,
            useIPv4: false,
            useIPv6: false,
            forwardAgent: false,
            compressionEnabled: false,
            sshOptions: []
        )

        try await service.removeRemoteIntegration(
            routeIDs: [routeB, routeA, routeA],
            session: session
        )

        let capturedInvocation = await executor.lastInvocation()
        let invocation = try #require(capturedInvocation)
        #expect(invocation.executable == "/usr/bin/ssh")
        #expect(invocation.arguments.contains("bridge-test.invalid"))
        let remoteCommand = try #require(invocation.arguments.last)
        #expect(remoteCommand.contains(routeA.uuidString.lowercased()))
        #expect(remoteCommand.contains(routeB.uuidString.lowercased()))
        #expect(remoteCommand.contains(" && "))
        #expect(!remoteCommand.contains("0x11"))
        let tokenA = try await tokenStore.token(for: routeA)
        let tokenB = try await tokenStore.token(for: routeB)
        #expect(tokenA == nil)
        #expect(tokenB == nil)
    }

    @Test
    func failedRemoteCleanupRetainsTheLocalAuthenticationToken() async throws {
        let routeID = UUID(uuidString: "30000000-0000-4000-8000-000000000001")!
        let credentialID = UUID(uuidString: "40000000-0000-4000-8000-000000000001")!
        let token = Data(repeating: 0x44, count: 32)
        let tokenStore = TokenStore()
        try await tokenStore.store(token: token, for: routeID, credentialID: credentialID)
        let service = UniConnectClaudeBridgeMaintenanceService(
            tokenStore: tokenStore,
            commandExecutor: Executor(shouldFail: true),
            installationKey: SymmetricKey(data: Data(repeating: 0x55, count: 32))
        )
        let session = DetectedSSHSession(
            destination: "bridge-test.invalid",
            port: nil,
            identityFile: nil,
            configFile: nil,
            jumpHost: nil,
            controlPath: nil,
            useIPv4: false,
            useIPv6: false,
            forwardAgent: false,
            compressionEnabled: false,
            sshOptions: []
        )

        await #expect(throws: Executor.StubError.self) {
            try await service.removeRemoteIntegration(routeIDs: [routeID], session: session)
        }
        let retained = try await tokenStore.token(for: routeID)
        #expect(retained == token)
    }

    @Test
    func localRouteTokenVaultIsEncryptedAndPrivate() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-bridge-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("tokens.uc")
        let key = SymmetricKey(data: Data(repeating: 0x66, count: 32))
        let routeID = UUID(uuidString: "50000000-0000-4000-8000-000000000001")!
        let credentialID = UUID(uuidString: "60000000-0000-4000-8000-000000000001")!
        let token = Data(repeating: 0x77, count: 32)
        let vault = UniConnectClaudeBridgeTokenVault(fileURL: fileURL, key: key)

        try await vault.store(token: token, for: routeID, credentialID: credentialID)

        let encrypted = try Data(contentsOf: fileURL)
        #expect(encrypted.range(of: token) == nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        let reloaded = UniConnectClaudeBridgeTokenVault(fileURL: fileURL, key: key)
        let recovered = try await reloaded.token(for: routeID)
        #expect(recovered == token)
    }
}
