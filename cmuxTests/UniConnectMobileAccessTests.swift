import CMUXMobileCore
import Foundation
import Network
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#else
@testable import cmux
#endif

@Suite("Direct Tailscale device approvals", .timeLimit(.minutes(1)))
@MainActor
struct UniConnectMobileAccessTests {
    @Test func explicitApprovalIsRequiredAndPersistedBeforeAccess() async {
        let repository = MobileApprovalFixtureRepository()
        let model = UniConnectMobileAccessModel(repository: repository)
        #expect(!model.authorize(address: "100.64.1.2"))
        #expect(model.pendingPeers.isEmpty)
        await model.load()
        #expect(!model.authorize(address: "100.64.1.2", deviceLabel: "Phone"))
        #expect(model.pendingPeers.map(\.address) == ["100.64.1.2"])
        await model.approve(address: "100.64.1.2")
        #expect(model.authorize(address: "100.64.1.2"))
        #expect(await repository.persistedPeers().map(\.address) == ["100.64.1.2"])
        #expect(model.pendingPeers.isEmpty)

        let restored = UniConnectMobileAccessModel(repository: repository)
        await restored.load()
        #expect(restored.authorize(address: "100.64.1.2"))
        #expect(!restored.authorize(address: "100.64.1.3", deviceLabel: "Phone"))
    }

    @Test func pendingRequestsAreBoundedAndCannotExtendTheirOwnTTL() async {
        let clock = MobileApprovalFixtureClock()
        let model = UniConnectMobileAccessModel(repository: MobileApprovalFixtureRepository(), now: { clock.now() })
        await model.load()
        for host in 1...32 { #expect(!model.authorize(address: "100.64.1.\(host)")) }
        #expect(model.pendingPeers.count == 8)
        let expiry = model.pendingPeers.first?.expiresAt
        clock.advance(seconds: 90)
        #expect(!model.authorize(address: "100.64.1.1"))
        #expect(model.pendingPeers.first?.expiresAt == expiry)
        clock.advance(seconds: 31)
        await model.approve(address: "100.64.1.1")
        #expect(model.pendingPeers.isEmpty)
        #expect(model.approvedPeers.isEmpty)
    }

    @Test func rejectSuppressesImmediateRepeatedPrompts() async {
        let clock = MobileApprovalFixtureClock()
        let model = UniConnectMobileAccessModel(repository: MobileApprovalFixtureRepository(), now: { clock.now() })
        await model.load()
        #expect(!model.authorize(address: "100.64.1.2"))
        model.reject(address: "100.64.1.2")
        for _ in 0..<32 { #expect(!model.authorize(address: "100.64.1.2")) }
        #expect(model.pendingPeers.isEmpty)
        clock.advance(seconds: 121)
        #expect(!model.authorize(address: "100.64.1.2"))
        #expect(model.pendingPeers.count == 1)
    }

    @Test func saveFailureNeverGrantsTemporaryAccess() async {
        let repository = MobileApprovalFixtureRepository()
        let model = UniConnectMobileAccessModel(repository: repository)
        await model.load()
        #expect(!model.authorize(address: "100.64.1.2"))
        await repository.setFailWrites(true)
        await model.approve(address: "100.64.1.2")
        #expect(!model.authorize(address: "100.64.1.2"))
        #expect(model.approvedPeers.isEmpty)
        #expect(model.lastError != nil)
    }

    @Test func revocationEmitsDisconnectAndRemainsBlockedOnDiskFailure() async throws {
        let repository = MobileApprovalFixtureRepository()
        let model = UniConnectMobileAccessModel(repository: repository)
        await model.load()
        #expect(!model.authorize(address: "100.64.1.2"))
        await model.approve(address: "100.64.1.2")
        var revocations = model.revocations().makeAsyncIterator()
        await repository.setFailWrites(true)
        await model.revoke(address: "100.64.1.2")
        #expect(await revocations.next() == "100.64.1.2")
        #expect(!model.authorize(address: "100.64.1.2"))
        #expect(model.pendingPeers.isEmpty)
        #expect(model.lastError != nil)
    }

    @Test func everyRPCRequiresObservedPeerApprovalRegardlessOfClaimedCredentials() async throws {
        let model = UniConnectMobileAccessModel(repository: MobileApprovalFixtureRepository())
        let authorizer = UniConnectMobileRequestAuthorizer(access: model)
        let observed = try #require(TailnetPeerAddress("100.64.1.2"))
        for method in ["mobile.host.status", "workspace.list", "mobile.events.subscribe", "mobile.terminal.input", "mobile.attach_ticket.create"] {
            let request = MobileHostRPCRequest(
                id: "fixture", method: method,
                params: ["peer_ip": "100.64.1.3", "approved": true, "device_name": "Approved device"],
                auth: MobileHostRPCAuth(attachToken: "fixture-only", stackAccessToken: "fixture-only")
            )
            let result = await authorizer.authorizationError(for: request, observedPeer: observed)
            guard case let .failure(error)? = result else {
                Issue.record("Unapproved endpoint passed the shared gate for \(method)")
                continue
            }
            #expect(error.code == "approval_required")
            #expect(error.data == nil)
        }
        #expect(model.pendingPeers.map(\.address) == [observed.rawValue])
        await model.approve(address: observed.rawValue)
        let request = MobileHostRPCRequest(id: "fixture", method: "workspace.list", params: [:], auth: nil)
        #expect(await authorizer.authorizationError(for: request, observedPeer: observed) == nil)
        let other = try #require(TailnetPeerAddress("100.64.1.3"))
        #expect(await authorizer.authorizationError(for: request, observedPeer: other) != nil)
    }

    @Test func unreadableApprovalStorageFailsClosedWithoutPublishingRequests() async throws {
        let repository = MobileApprovalFixtureRepository(failReads: true)
        let model = UniConnectMobileAccessModel(repository: repository)
        let authorizer = UniConnectMobileRequestAuthorizer(access: model)
        let request = MobileHostRPCRequest(id: "fixture", method: "workspace.list", params: [:], auth: nil)
        let peer = try #require(TailnetPeerAddress("100.64.1.2"))
        let result = await authorizer.authorizationError(for: request, observedPeer: peer)
        guard case let .failure(error)? = result else { Issue.record("Storage failure granted access"); return }
        #expect(error.code == "access_unavailable")
        #expect(!model.isLoaded)
        #expect(model.pendingPeers.isEmpty)
    }

    @Test func endpointPolicyRejectsDNSClaimsAndNormalizesMappedAddresses() throws {
        let port = try #require(NWEndpoint.Port(rawValue: 58465))
        #expect(UniConnectMobilePeerEndpoint.tailnetAddress(from: .hostPort(host: .name("100.64.1.2", nil), port: port)) == nil)
        #expect(UniConnectMobilePeerEndpoint.tailnetAddress(from: .hostPort(host: .name("phone.tailnet.ts.net", nil), port: port)) == nil)
        let mapped = try #require(IPv6Address("::ffff:100.64.1.2"))
        #expect(UniConnectMobilePeerEndpoint.tailnetAddress(from: .hostPort(host: .ipv6(mapped), port: port)) == "100.64.1.2")
        let lan = try #require(IPv4Address("192.168.1.2"))
        #expect(UniConnectMobilePeerEndpoint.tailnetAddress(from: .hostPort(host: .ipv4(lan), port: port)) == nil)
    }

    @Test func approvalFileRoundTripsInPrivateStorage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("uniconnect-mobile-approval-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("approved-peers.json")
        let repository = UniConnectMobileAccessFileRepository(fileURL: file)
        #expect(try await repository.load().isEmpty)
        let peer = UniConnectMobileApprovedPeer(address: "100.64.1.2", label: "Fixture", approvedAt: Date(timeIntervalSince1970: 1))
        try await repository.save([peer])
        #expect(try await repository.load() == [peer])
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        try await repository.save([])
        #expect(try await repository.load().isEmpty)
    }
}

private actor MobileApprovalFixtureRepository: UniConnectMobileAccessRepository {
    private var peers: [UniConnectMobileApprovedPeer] = []
    private let failReads: Bool
    private var failWrites = false
    init(failReads: Bool = false) { self.failReads = failReads }
    func load() throws -> [UniConnectMobileApprovedPeer] {
        if failReads { throw FixtureError.unavailable }
        return peers
    }
    func save(_ peers: [UniConnectMobileApprovedPeer]) throws {
        if failWrites { throw FixtureError.unavailable }
        self.peers = peers
    }
    func setFailWrites(_ value: Bool) { failWrites = value }
    func persistedPeers() -> [UniConnectMobileApprovedPeer] { peers }
    private enum FixtureError: Error { case unavailable }
}

/// The injected model clock and test are both isolated to the main actor.
@MainActor
private final class MobileApprovalFixtureClock {
    private var instant = Date(timeIntervalSince1970: 1_000)
    func now() -> Date { instant }
    func advance(seconds: TimeInterval) { instant.addTimeInterval(seconds) }
}
