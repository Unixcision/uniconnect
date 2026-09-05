import Foundation

/// Coordinates route registration, authenticated ingestion, notification delivery, and status.
public actor ClaudeBridgeService {
    private struct RegisteredRoute: Sendable {
        var route: ClaudeBridgeRoute
        let generation: UUID
        let connectionID: UUID?
        var token: Data?
    }

    private let tokenStore: any ClaudeBridgeTokenStoring
    private let notificationDelivery: any ClaudeBridgeNotificationDelivering
    private let authenticator: ClaudeBridgeAuthenticator
    private let enrollmentTimeout: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var routes: [UUID: RegisteredRoute] = [:]
    private var statuses: [UUID: ClaudeBridgeStatus] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingRegistrationGenerations: [UUID: UUID] = [:]
    private var isShutdown = false
    private let statusContinuation: AsyncStream<ClaudeBridgeStatusUpdate>.Continuation
    private let sessionSignalContinuation: AsyncStream<ClaudeBridgeSessionSignal>.Continuation

    /// Route status changes, emitted as immutable values for UI snapshot builders.
    public nonisolated let statusUpdates: AsyncStream<ClaudeBridgeStatusUpdate>

    /// Authenticated, privacy-minimized session events for non-polling updater coordination.
    public nonisolated let sessionSignals: AsyncStream<ClaudeBridgeSessionSignal>

    /// Creates the bridge service with explicit persistence and notification dependencies.
    ///
    /// - Parameters:
    ///   - tokenStore: Encrypted per-route token repository.
    ///   - notificationDelivery: Main-actor delivery boundary into the app.
    ///   - enrollmentTimeout: Bounded time for enrollment, remote publication, and signed confirmation.
    ///   - now: Injectable clock used for deterministic freshness tests.
    ///   - sleep: Injectable one-shot timeout suspension; it is never used for polling.
    public init(
        tokenStore: any ClaudeBridgeTokenStoring,
        notificationDelivery: any ClaudeBridgeNotificationDelivering,
        enrollmentTimeout: Duration = .seconds(30),
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.tokenStore = tokenStore
        self.notificationDelivery = notificationDelivery
        self.authenticator = ClaudeBridgeAuthenticator(now: now)
        self.enrollmentTimeout = enrollmentTimeout
        self.sleep = sleep
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
        self.decoder = JSONDecoder()
        let stream = AsyncStream<ClaudeBridgeStatusUpdate>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        self.statusUpdates = stream.stream
        self.statusContinuation = stream.continuation
        let signalStream = AsyncStream<ClaudeBridgeSessionSignal>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        self.sessionSignals = signalStream.stream
        self.sessionSignalContinuation = signalStream.continuation
    }

    /// Registers a trusted local route before its SSH reverse-forward starts.
    ///
    /// - Parameters:
    ///   - route: Trusted routing metadata assembled by the app.
    ///   - connectionID: Current SSH attempt identity, required on its wire messages when supplied.
    public func register(route: ClaudeBridgeRoute, connectionID: UUID? = nil) async {
        guard !isShutdown, !Task.isCancelled else { return }
        let generation = UUID()
        timeoutTasks.removeValue(forKey: route.id)?.cancel()
        pendingRegistrationGenerations[route.id] = generation
        defer {
            if pendingRegistrationGenerations[route.id] == generation {
                pendingRegistrationGenerations.removeValue(forKey: route.id)
            }
        }
        let storedToken: Data?
        do {
            storedToken = try await tokenStore.token(
                for: route.id,
                credentialID: route.credentialID
            )
        } catch {
            guard !isShutdown, !Task.isCancelled,
                  pendingRegistrationGenerations[route.id] == generation else {
                if pendingRegistrationGenerations[route.id] == generation {
                    pendingRegistrationGenerations.removeValue(forKey: route.id)
                }
                return
            }
            await authenticator.unregister(routeID: route.id)
            guard !isShutdown, !Task.isCancelled,
                  pendingRegistrationGenerations[route.id] == generation else {
                return
            }
            pendingRegistrationGenerations.removeValue(forKey: route.id)
            routes[route.id] = RegisteredRoute(
                route: route, generation: generation, connectionID: connectionID, token: nil
            )
            updateStatus(.error(.tokenStore), routeID: route.id)
            return
        }

        guard !isShutdown, !Task.isCancelled,
              pendingRegistrationGenerations[route.id] == generation else {
            if pendingRegistrationGenerations[route.id] == generation {
                pendingRegistrationGenerations.removeValue(forKey: route.id)
            }
            return
        }
        if let storedToken, storedToken.count == 32 {
            await authenticator.register(token: storedToken, for: route.id)
        } else {
            await authenticator.unregister(routeID: route.id)
        }
        guard !isShutdown, !Task.isCancelled,
              pendingRegistrationGenerations[route.id] == generation else {
            return
        }
        pendingRegistrationGenerations.removeValue(forKey: route.id)
        routes[route.id] = RegisteredRoute(
            route: route, generation: generation, connectionID: connectionID, token: storedToken
        )
        updateStatus(.reconnecting, routeID: route.id)
        scheduleEnrollmentTimeout(routeID: route.id, generation: generation)
    }

    /// Processes one bounded JSON frame from the loopback-only listener.
    ///
    /// - Parameter data: A single newline-delimited JSON frame of at most 16 KiB.
    /// - Returns: A bounded JSON response with no reflected untrusted content.
    public func ingest(_ data: Data) async -> Data {
        guard !isShutdown else {
            return encodedResponse(.init(accepted: false, code: "shutdown"))
        }
        guard !data.isEmpty, data.count <= 16 * 1_024,
              let message = try? decoder.decode(ClaudeBridgeWireMessage.self, from: data),
              let routeID = UUID(uuidString: message.routeID),
              let registered = routes[routeID] else {
            return encodedResponse(.init(accepted: false, code: "malformed"))
        }
        guard pendingRegistrationGenerations[routeID] == nil else {
            return encodedResponse(.init(accepted: false, code: "route_changed"))
        }
        if let connectionID = registered.connectionID,
           message.connectionID.flatMap(UUID.init(uuidString:)) != connectionID {
            return encodedResponse(.init(accepted: false, code: "superseded"))
        }

        switch message.message {
        case .enroll:
            return await ingestEnrollment(message, routeID: routeID, registered: registered)
        case .hello, .event:
            return await ingestAuthenticated(message, routeID: routeID, registered: registered)
        }
    }

    /// Marks a known route as reconnecting before a replacement SSH process starts.
    ///
    /// - Parameter routeID: Stable route UUID.
    public func markReconnecting(routeID: UUID) {
        guard routes[routeID] != nil else { return }
        updateStatus(.reconnecting, routeID: routeID)
    }

    /// Marks a known route unavailable using a stable localizable reason.
    ///
    /// - Parameters:
    ///   - routeID: Stable route UUID.
    ///   - reason: Non-sensitive availability reason.
    public func markUnavailable(routeID: UUID, reason: ClaudeBridgeUnavailableReason) {
        guard routes[routeID] != nil else { return }
        updateStatus(.unavailable(reason), routeID: routeID)
    }

    /// Stops tracking one route and optionally removes its local HMAC token.
    ///
    /// - Parameters:
    ///   - routeID: Stable route UUID.
    ///   - removeToken: Whether the encrypted token should also be deleted.
    public func unregister(routeID: UUID, removeToken: Bool) async {
        pendingRegistrationGenerations.removeValue(forKey: routeID)
        timeoutTasks.removeValue(forKey: routeID)?.cancel()
        routes.removeValue(forKey: routeID)
        statuses.removeValue(forKey: routeID)
        statusContinuation.yield(.init(routeID: routeID, status: .inactive))
        await authenticator.unregister(routeID: routeID)
        if removeToken {
            do {
                try await tokenStore.removeToken(for: routeID)
            } catch {
                guard !isShutdown, routes[routeID] == nil,
                      pendingRegistrationGenerations[routeID] == nil else { return }
                statusContinuation.yield(.init(routeID: routeID, status: .error(.tokenStore)))
            }
        }
    }

    /// Returns route UUIDs grouped under one encrypted SSH credential.
    ///
    /// - Parameter credentialID: Vault credential UUID.
    /// - Returns: Stable route UUIDs, or an empty array if encrypted storage is unavailable.
    public func routeIDs(for credentialID: UUID) async -> [UUID] {
        (try? await tokenStore.routeIDs(for: credentialID)) ?? []
    }

    /// Returns the latest immutable status for a route.
    ///
    /// - Parameter routeID: Stable route UUID.
    /// - Returns: The current status, or `.inactive` for an unknown route.
    public func status(for routeID: UUID) -> ClaudeBridgeStatus {
        statuses[routeID] ?? .inactive
    }

    /// Rebinds presentation metadata after the same terminal surface moves workspaces.
    ///
    /// Connection identity remains immutable: the surface, credential, host, and tmux
    /// session must match the registered route. Only the trusted local workspace and
    /// display names may change.
    ///
    /// - Parameter route: Updated trusted local route metadata.
    /// - Returns: True when the registered route accepted the rebind.
    @discardableResult
    public func rebind(route: ClaudeBridgeRoute) -> Bool {
        guard !isShutdown,
              var current = routes[route.id],
              route.surfaceID == current.route.surfaceID,
              route.credentialID == current.route.credentialID,
              route.hostLabel == current.route.hostLabel,
              route.tmuxSession == current.route.tmuxSession else {
            return false
        }
        current.route = route
        routes[route.id] = current
        return true
    }

    /// Cancels route timeouts and finishes the status stream during app termination.
    public func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        for task in timeoutTasks.values {
            task.cancel()
        }
        timeoutTasks.removeAll()
        pendingRegistrationGenerations.removeAll()
        routes.removeAll()
        statuses.removeAll()
        statusContinuation.finish()
        sessionSignalContinuation.finish()
    }

    private func ingestEnrollment(
        _ message: ClaudeBridgeWireMessage,
        routeID: UUID,
        registered: RegisteredRoute
    ) async -> Data {
        guard message.eventType == nil,
              message.sessionCorrelation == nil,
              message.cwd == nil,
              message.tmuxPane == nil,
              message.signature == nil,
              message.integrationReady != nil,
              let tokenText = message.token,
              let token = Data(base64Encoded: tokenText),
              token.count == 32 else {
            updateStatus(.error(.authentication), routeID: routeID)
            return encodedResponse(.init(accepted: false, code: "invalid_enrollment"))
        }

        if let storedToken = registered.token, storedToken != token {
            updateStatus(.error(.authentication), routeID: routeID)
            return encodedResponse(.init(accepted: false, code: "token_mismatch"))
        }

        let acceptance = await authenticator.acceptEnrollment(message, expectedRouteID: routeID)
        guard isCurrent(routeID: routeID, generation: registered.generation) else {
            return encodedResponse(.init(accepted: false, code: "route_changed"))
        }
        switch acceptance {
        case .success:
            break
        case .failure(.duplicate):
            return encodedResponse(.init(accepted: false, duplicate: true))
        case .failure(.stale):
            return encodedResponse(.init(accepted: false, code: "stale"))
        case .failure(.capacity):
            return encodedResponse(.init(accepted: false, code: "capacity"))
        case .failure(.malformed), .failure(.unauthenticated), .failure(.unknownRoute):
            updateStatus(.error(.authentication), routeID: routeID)
            return encodedResponse(.init(accepted: false, code: "invalid_enrollment"))
        }

        if registered.token == nil {
            do {
                try await tokenStore.store(
                    token: token,
                    for: routeID,
                    credentialID: registered.route.credentialID
                )
            } catch {
                guard isCurrent(routeID: routeID, generation: registered.generation) else {
                    return encodedResponse(.init(accepted: false, code: "route_changed"))
                }
                updateStatus(.error(.tokenStore), routeID: routeID)
                return encodedResponse(.init(accepted: false, code: "token_store"))
            }
            guard isCurrent(routeID: routeID, generation: registered.generation),
                  var current = routes[routeID] else {
                return encodedResponse(.init(accepted: false, code: "route_changed"))
            }
            current.token = token
            routes[routeID] = current
        }

        await authenticator.register(token: token, for: routeID)
        guard isCurrent(routeID: routeID, generation: registered.generation) else {
            return encodedResponse(.init(accepted: false, code: "route_changed"))
        }
        if message.integrationReady == false {
            timeoutTasks.removeValue(forKey: routeID)?.cancel()
            updateStatus(
                .unavailable(unavailableReason(forRemoteCode: message.integrationError)),
                routeID: routeID
            )
        } else if registered.connectionID == nil {
            timeoutTasks.removeValue(forKey: routeID)?.cancel()
            updateStatus(.active, routeID: routeID)
        }
        // A bound connection is ready only after the remote route file is published
        // and a signed hello/event arrives. Accepting enrollment alone proves neither.
        return encodedResponse(.init(accepted: true))
    }

    private func ingestAuthenticated(
        _ message: ClaudeBridgeWireMessage,
        routeID: UUID,
        registered: RegisteredRoute
    ) async -> Data {
        let authentication = await authenticator.authenticate(message, expectedRouteID: routeID)
        guard isCurrent(routeID: routeID, generation: registered.generation),
              let current = routes[routeID] else {
            return encodedResponse(.init(accepted: false, code: "route_changed"))
        }
        switch authentication {
        case .success(nil):
            timeoutTasks.removeValue(forKey: routeID)?.cancel()
            updateStatus(.active, routeID: routeID)
            return encodedResponse(.init(accepted: true))
        case .success(let event?):
            timeoutTasks.removeValue(forKey: routeID)?.cancel()
            updateStatus(.active, routeID: routeID)
            if let tmuxPane = event.tmuxPane {
                sessionSignalContinuation.yield(.init(
                    routeID: routeID,
                    sessionID: event.sessionCorrelation,
                    cwd: event.cwd,
                    tmuxPane: tmuxPane,
                    kind: event.kind,
                    occurredAt: event.occurredAt
                ))
            }
            if event.kind.isUserVisibleCompletion {
                await notificationDelivery.deliver(event: event, route: current.route)
            }
            return encodedResponse(.init(accepted: true))
        case .failure(.duplicate):
            return encodedResponse(.init(accepted: false, duplicate: true))
        case .failure(.stale):
            return encodedResponse(.init(accepted: false, code: "stale"))
        case .failure(.malformed):
            return encodedResponse(.init(accepted: false, code: "malformed"))
        case .failure(.capacity):
            return encodedResponse(.init(accepted: false, code: "capacity"))
        case .failure(.unauthenticated), .failure(.unknownRoute):
            updateStatus(.error(.authentication), routeID: routeID)
            return encodedResponse(.init(accepted: false, code: "unauthenticated"))
        }
    }

    private func scheduleEnrollmentTimeout(routeID: UUID, generation: UUID) {
        timeoutTasks.removeValue(forKey: routeID)?.cancel()
        let sleeper = sleep
        let duration = enrollmentTimeout
        timeoutTasks[routeID] = Task { [weak self] in
            do {
                try await sleeper(duration)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.expireEnrollment(routeID: routeID, generation: generation)
        }
    }

    private func expireEnrollment(routeID: UUID, generation: UUID) {
        guard isCurrent(routeID: routeID, generation: generation) else { return }
        defer { timeoutTasks.removeValue(forKey: routeID) }
        guard statuses[routeID] == .reconnecting else { return }
        updateStatus(.unavailable(.enrollmentTimedOut), routeID: routeID)
    }

    /// Rejects work that resumed after replacement, removal, cancellation, or shutdown.
    private func isCurrent(routeID: UUID, generation: UUID) -> Bool {
        !isShutdown && !Task.isCancelled
            && pendingRegistrationGenerations[routeID] == nil
            && routes[routeID]?.generation == generation
    }

    private func unavailableReason(forRemoteCode code: String?) -> ClaudeBridgeUnavailableReason {
        switch code {
        case "python3_missing": return .remoteRuntime
        case "settings_invalid", "settings_write_failed": return .remoteSettings
        default: return .reverseForward
        }
    }

    private func updateStatus(_ status: ClaudeBridgeStatus, routeID: UUID) {
        guard statuses[routeID] != status else { return }
        statuses[routeID] = status
        statusContinuation.yield(.init(routeID: routeID, status: status))
    }

    private func encodedResponse(_ response: ClaudeBridgeIngestResponse) -> Data {
        (try? encoder.encode(response)) ?? Data(#"{"accepted":false,"duplicate":false,"code":"encoding"}"#.utf8)
    }
}
