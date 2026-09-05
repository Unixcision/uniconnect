import CMUXMobileCore
import Foundation
import Observation

/// Local approvals for the direct Tailscale transport. No account or bearer
/// credential can grant access in place of a locally approved observed IP.
@MainActor @Observable
final class UniConnectMobileAccessModel {
    private(set) var approvedPeers: [UniConnectMobileApprovedPeer] = []
    private(set) var pendingPeers: [UniConnectMobilePendingPeer] = []
    private(set) var isLoaded = false
    private(set) var isSaving = false
    private(set) var lastError: String?

    @ObservationIgnored private let repository: any UniConnectMobileAccessRepository
    @ObservationIgnored private let now: @MainActor @Sendable () -> Date
    @ObservationIgnored private var loading: Task<[UniConnectMobileApprovedPeer], Error>?
    @ObservationIgnored private var expirationTask: Task<Void, Never>?
    @ObservationIgnored private var rejectedUntil: [String: Date] = [:]
    @ObservationIgnored private var revocationObservers: [UUID: AsyncStream<String>.Continuation] = [:]

    init(repository: any UniConnectMobileAccessRepository, now: @escaping @MainActor @Sendable () -> Date = Date.init) {
        self.repository = repository
        self.now = now
    }

    deinit { expirationTask?.cancel() }

    func load() async {
        guard !isLoaded else { return }
        let task: Task<[UniConnectMobileApprovedPeer], Error>
        if let loading { task = loading }
        else {
            task = Task { try await repository.load() }
            loading = task
        }
        do {
            let peers = try await task.value
            // Several connections may await the same initial load. A later
            // waiter must never overwrite an approval or revocation made since.
            guard !isLoaded else { return }
            approvedPeers = peers.sorted { $0.approvedAt < $1.approvedAt }
            isLoaded = true
            lastError = nil
        } catch {
            lastError = String(localized: "uniconnect.mobile.access.loadFailed", defaultValue: "No se pudieron leer los dispositivos autorizados. El acceso permanece bloqueado.")
        }
        loading = nil
    }

    /// Only the server supplies `address`, from NWConnection's numeric endpoint.
    func authorize(address: String, deviceLabel: String? = nil) -> Bool {
        guard isLoaded, let peer = TailnetPeerAddress(address) else { return false }
        if approvedPeers.contains(where: { $0.address == peer.rawValue }) { return true }
        expirePendingRequests()
        let instant = now()
        guard rejectedUntil[peer.rawValue].map({ $0 <= instant }) ?? true,
              !pendingPeers.contains(where: { $0.address == peer.rawValue }), pendingPeers.count < 8 else { return false }
        pendingPeers.append(UniConnectMobilePendingPeer(
            address: peer.rawValue,
            label: Self.safeLabel(deviceLabel, fallback: peer.rawValue),
            requestedAt: instant,
            expiresAt: instant.addingTimeInterval(120)
        ))
        scheduleExpiration()
        return false
    }

    func approve(address: String, label: String? = nil) async {
        guard isLoaded, !isSaving, approvedPeers.count < 128 else { return }
        expirePendingRequests()
        guard let pending = pendingPeers.first(where: { $0.address == address }) else { return }
        isSaving = true
        defer { isSaving = false }
        let peer = UniConnectMobileApprovedPeer(
            address: pending.address,
            label: Self.safeLabel(label, fallback: pending.label),
            approvedAt: now()
        )
        let updated = approvedPeers + [peer]
        do {
            // Do not authorize even briefly when durable persistence failed.
            try await repository.save(updated)
            approvedPeers = updated
            pendingPeers.removeAll { $0.address == address }
            rejectedUntil.removeValue(forKey: address)
            lastError = nil
        } catch {
            lastError = String(localized: "uniconnect.mobile.access.saveFailed", defaultValue: "No se pudo guardar el cambio de permisos. Revisa el acceso al almacenamiento.")
        }
    }

    func reject(address: String) {
        guard !isSaving, pendingPeers.contains(where: { $0.address == address }) else { return }
        pendingPeers.removeAll { $0.address == address }
        rememberRejection(address)
    }

    func revoke(address: String) async {
        guard isLoaded, !isSaving, approvedPeers.contains(where: { $0.address == address }) else { return }
        isSaving = true
        defer { isSaving = false }
        approvedPeers.removeAll { $0.address == address }
        pendingPeers.removeAll { $0.address == address }
        rememberRejection(address)
        for observer in revocationObservers.values { observer.yield(address) }
        do {
            try await repository.save(approvedPeers)
            lastError = nil
        } catch {
            // Keep the peer blocked in memory and disconnect it even if disk
            // fails. The UI must not claim that this revocation was persisted.
            lastError = String(localized: "uniconnect.mobile.access.revokeFailed", defaultValue: "El dispositivo está desconectado, pero no se pudo guardar la revocación. Puede recuperar el permiso al reiniciar.")
        }
    }

    func revocations() -> AsyncStream<String> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(128))
        revocationObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in self?.revocationObservers.removeValue(forKey: id) }
        }
        return stream
    }

    func expirePendingRequests() {
        let instant = now()
        if pendingPeers.contains(where: { $0.expiresAt <= instant }) {
            pendingPeers.removeAll { $0.expiresAt <= instant }
        }
        rejectedUntil = rejectedUntil.filter { $0.value > instant }
    }

    private func rememberRejection(_ address: String) {
        rejectedUntil[address] = now().addingTimeInterval(120)
        if rejectedUntil.count > 128, let oldest = rejectedUntil.min(by: { $0.value < $1.value })?.key {
            rejectedUntil.removeValue(forKey: oldest)
        }
    }

    private func scheduleExpiration() {
        expirationTask?.cancel()
        guard let expiry = pendingPeers.map(\.expiresAt).min() else { return }
        let delay = max(0, expiry.timeIntervalSince(now()))
        expirationTask = Task { [weak self] in
            // This cancellable delay is the request's expiry deadline, not polling.
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.expirePendingRequests()
            self?.scheduleExpiration()
        }
    }

    private static func safeLabel(_ label: String?, fallback: String) -> String {
        let cleaned = String((label ?? "").unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : String(cleaned.prefix(80))
    }
}
