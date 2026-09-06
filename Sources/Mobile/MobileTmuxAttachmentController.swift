import CoreFoundation
import Foundation

/// Owns the bounded tmux clients of one authenticated mobile connection.
actor MobileTmuxAttachmentController {
    typealias Event = MobileTmuxAttachmentEvent
    typealias Resolver = @Sendable (UUID, UUID) async throws -> MobileTmuxAttachPlan
    typealias ProcessFactory = @Sendable () -> any MobilePTYRunning

    private struct Attachment {
        let id: UUID
        let workspaceID: UUID
        let surfaceID: UUID
        let process: any MobilePTYRunning
        var columns: Int
        var rows: Int
        var plan: MobileTmuxAttachPlan?
        var stream: AsyncStream<MobilePTYOutput>?
        var preparation: Task<MobileHostRPCResult, Never>?
        var delivery: Task<Void, Never>?
        var sequence: UInt64 = 0
    }

    private let resolve: Resolver
    private let makeProcess: ProcessFactory
    private var attachments: [UUID: Attachment] = [:]
    private let maximumAttachments = 4
    private let maximumInputBytes = 64 * 1024

    init(resolve: @escaping Resolver, makeProcess: @escaping ProcessFactory) {
        self.resolve = resolve
        self.makeProcess = makeProcess
    }

    /// Reserves and starts a client without consuming output before its response is delivered.
    func prepareAttach(_ request: MobileHostRPCRequest, subscribed: Bool) async -> MobileHostRPCResult {
        guard subscribed else {
            return .failure(MobileHostRPCError(
                code: "subscription_required",
                message: String(localized: "mobile.tmux.subscriptionRequired", defaultValue: "Suscríbete a los eventos de terminal antes de conectar.")
            ))
        }
        guard let workspaceID = Self.uuid(request.params["workspace_id"]),
              let surfaceID = Self.uuid(request.params["surface_id"]),
              let columns = Self.dimension(request.params["columns"]),
              let rows = Self.dimension(request.params["rows"]) else {
            return Self.invalidParams
        }

        if let existing = attachments.values.first(where: {
            $0.workspaceID == workspaceID && $0.surfaceID == surfaceID
        }) {
            if let preparation = existing.preparation {
                let result = await preparation.value
                guard !Task.isCancelled else { return Self.closed }
                return result
            }
            guard await validate(existing.id), let current = attachments[existing.id] else {
                return Self.closed
            }
            return Self.attached(current)
        }

        guard attachments.count < maximumAttachments else {
            return .failure(MobileHostRPCError(
                code: "attachment_limit",
                message: String(localized: "mobile.tmux.attachmentLimit", defaultValue: "Esta conexión ya tiene cuatro terminales adjuntas.")
            ))
        }
        guard !Task.isCancelled else { return Self.closed }

        let id = UUID()
        // Reservation precedes the first await, so concurrent requests cannot duplicate a target.
        attachments[id] = Attachment(
            id: id, workspaceID: workspaceID, surfaceID: surfaceID,
            process: makeProcess(), columns: columns, rows: rows
        )
        let preparation = Task { await self.start(id) }
        attachments[id]?.preparation = preparation
        return await withTaskCancellationHandler {
            let result = await preparation.value
            guard !Task.isCancelled else {
                await close(id)
                return Self.closed
            }
            return result
        } onCancel: {
            preparation.cancel()
            Task { await self.close(id) }
        }
    }

    /// Call only after the attach response has physically completed on this connection's socket.
    func activate(attachID: UUID, send: @escaping @Sendable (Event) async -> Bool) {
        guard var attachment = attachments[attachID], attachment.delivery == nil,
              attachment.preparation == nil, let stream = attachment.stream else { return }
        attachment.stream = nil
        attachment.delivery = Task { [weak self] in
            for await output in stream {
                guard !Task.isCancelled, let self else { break }
                guard await self.deliver(output, id: attachID, send: send) else { break }
            }
            await self?.close(attachID)
        }
        attachments[attachID] = attachment
    }

    func handle(_ request: MobileHostRPCRequest) async -> MobileHostRPCResult {
        switch request.method {
        case "mobile.terminal.pty_input":
            return await input(request.params)
        case "mobile.terminal.pty_resize":
            return await resize(request.params)
        case "mobile.terminal.detach":
            guard let id = Self.uuid(request.params["attach_id"]) else { return Self.invalidParams }
            guard attachments[id] != nil else { return Self.closed }
            await close(id)
            return .ok(["ok": true, "attach_id": id.uuidString, "detached": true])
        default:
            return .failure(MobileHostRPCError(
                code: "method_not_found",
                message: String(localized: "mobile.tmux.unknownMethod", defaultValue: "La operación de terminal no está disponible.")
            ))
        }
    }

    /// Rechecks exact route identity after workspace, binding, credential, or vault changes.
    func revalidateAll() async {
        for id in Array(attachments.keys) {
            guard attachments[id]?.plan != nil else { continue }
            _ = await validate(id)
        }
    }

    /// Removes only this connection's PTY clients; closing them never kills their tmux sessions.
    func closeAll() async {
        let previous = Array(attachments.values)
        attachments.removeAll()
        for attachment in previous {
            attachment.preparation?.cancel()
            attachment.delivery?.cancel()
        }
        for attachment in previous {
            await attachment.process.close()
        }
    }

    private func start(_ id: UUID) async -> MobileHostRPCResult {
        guard let initial = attachments[id] else { return Self.closed }
        do {
            let plan = try await resolve(initial.workspaceID, initial.surfaceID)
            try Task.checkCancellation()
            guard plan.workspaceID == initial.workspaceID, plan.surfaceID == initial.surfaceID,
                  attachments[id] != nil else {
                await close(id)
                return Self.closed
            }
            attachments[id]?.plan = plan
            let stream = try await initial.process.start(
                command: plan.command, columns: initial.columns, rows: initial.rows
            )
            try Task.checkCancellation()
            guard await validate(id), var ready = attachments[id] else {
                await initial.process.close()
                return Self.closed
            }
            try Task.checkCancellation()
            ready.stream = stream
            ready.preparation = nil
            attachments[id] = ready
            return Self.attached(ready)
        } catch {
            await close(id)
            // The resolver and process may include credential paths or commands in their errors.
            // Only stable, localized errors are exposed to the remote client.
            if error is CancellationError { return Self.closed }
            if let attachError = error as? MobileTmuxAttachError {
                return .failure(MobileHostRPCError(
                    code: Self.code(for: attachError), message: attachError.localizedDescription
                ))
            }
            return .failure(MobileHostRPCError(
                code: "attach_failed",
                message: String(localized: "mobile.tmux.attachFailed", defaultValue: "No se pudo conectar con la sesión de terminal existente.")
            ))
        }
    }

    private func input(_ params: [String: Any]) async -> MobileHostRPCResult {
        guard let id = Self.uuid(params["attach_id"]), let encoded = params["data"] as? String,
              !encoded.isEmpty, encoded.utf8.count <= ((maximumInputBytes + 2) / 3) * 4,
              let bytes = Data(base64Encoded: encoded), !bytes.isEmpty,
              bytes.count <= maximumInputBytes, bytes.base64EncodedString() == encoded else {
            return Self.invalidParams
        }
        guard await validate(id), let attachment = attachments[id] else { return Self.closed }
        do {
            try await attachment.process.write(bytes)
            guard attachments[id] != nil else { return Self.closed }
            return .ok(["attach_id": id.uuidString, "queued": true])
        } catch {
            await close(id)
            return Self.ioFailed
        }
    }

    private func resize(_ params: [String: Any]) async -> MobileHostRPCResult {
        guard let id = Self.uuid(params["attach_id"]),
              let columns = Self.dimension(params["columns"]),
              let rows = Self.dimension(params["rows"]) else { return Self.invalidParams }
        guard await validate(id), let attachment = attachments[id] else { return Self.closed }
        do {
            try await attachment.process.resize(columns: columns, rows: rows)
            guard attachments[id] != nil else { return Self.closed }
            attachments[id]?.columns = columns
            attachments[id]?.rows = rows
            return .ok(["attach_id": id.uuidString, "columns": columns, "rows": rows])
        } catch {
            await close(id)
            return Self.ioFailed
        }
    }

    private func validate(_ id: UUID) async -> Bool {
        guard let initial = attachments[id], let plan = initial.plan else { return false }
        do {
            let currentPlan = try await resolve(initial.workspaceID, initial.surfaceID)
            guard attachments[id]?.plan == plan, currentPlan == plan else {
                await close(id)
                return false
            }
            return true
        } catch {
            await close(id)
            return false
        }
    }

    private func deliver(_ output: MobilePTYOutput, id: UUID, send: @Sendable (Event) async -> Bool) async -> Bool {
        guard await validate(id), var attachment = attachments[id], !Task.isCancelled else { return false }
        let event = Event(
            attachID: id, workspaceID: attachment.workspaceID, surfaceID: attachment.surfaceID,
            sequence: attachment.sequence, output: output
        )
        attachment.sequence += 1
        attachments[id] = attachment
        // A single stream consumer awaits each physical send; chunks cannot overtake each other.
        guard await send(event), attachments[id] != nil else {
            await close(id)
            return false
        }
        switch output {
        case .bytes:
            return true
        case .exited, .failed:
            await close(id)
            return false
        }
    }

    private func close(_ id: UUID) async {
        guard let attachment = attachments.removeValue(forKey: id) else { return }
        attachment.preparation?.cancel()
        attachment.delivery?.cancel()
        await attachment.process.close()
    }

    private static func uuid(_ raw: Any?) -> UUID? {
        guard let text = raw as? String, text.utf8.count == 36, let value = UUID(uuidString: text),
              value.uuidString.caseInsensitiveCompare(text) == .orderedSame else { return nil }
        return value
    }

    private static func dimension(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value.rounded(.towardZero) == value, (1...1000).contains(value) else { return nil }
        return Int(value)
    }

    private static func attached(_ attachment: Attachment) -> MobileHostRPCResult {
        .ok([
            "attach_id": attachment.id.uuidString,
            "workspace_id": attachment.workspaceID.uuidString,
            "surface_id": attachment.surfaceID.uuidString,
            "columns": attachment.columns,
            "rows": attachment.rows,
        ])
    }

    private static func code(for error: MobileTmuxAttachError) -> String {
        switch error {
        case .locked: "locked"
        case .targetUnavailable, .targetChanged: "surface_unavailable"
        case .legacyTerminal: "not_durable"
        case .invalidSSHCredential: "invalid_ssh_credential"
        case .missingTmux: "tmux_unavailable"
        case .unsupportedTmux: "tmux_unsupported"
        case .missingSession: "session_not_found"
        }
    }

    private static var invalidParams: MobileHostRPCResult {
        .failure(MobileHostRPCError(
            code: "invalid_params",
            message: String(localized: "mobile.tmux.invalidParams", defaultValue: "Los identificadores, dimensiones o datos de terminal no son válidos.")
        ))
    }

    private static var closed: MobileHostRPCResult {
        .failure(MobileHostRPCError(
            code: "attachment_not_found",
            message: String(localized: "mobile.tmux.attachmentNotFound", defaultValue: "La terminal adjunta ya no está disponible en esta conexión.")
        ))
    }

    private static var ioFailed: MobileHostRPCResult {
        .failure(MobileHostRPCError(
            code: "pty_io_failed",
            message: String(localized: "mobile.tmux.ioFailed", defaultValue: "La conexión con la terminal se ha cerrado.")
        ))
    }
}
