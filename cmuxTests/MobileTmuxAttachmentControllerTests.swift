import CMUXMobileCore
import Foundation
@preconcurrency import Network
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#else
@testable import cmux
#endif

@Suite("Connection-owned mobile tmux attachments", .timeLimit(.minutes(1)))
struct MobileTmuxAttachmentControllerTests {
    @Test func fragmentedGeometryPreservesTerminalBytesAndIncompleteFrames() throws {
        let nonce = UUID()
        let token = nonce.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let marker = Data(("\u{001e}UCPTY_GEOMETRY_\(token):120:40:on\u{001f}").utf8)
        let foreign = Data("\u{001e}UCPTY_GEOMETRY_foreign:80:24:on\u{001f}".utf8)
        let suffix = Data(("\u{001e}UCPTY_GEOMETRY_\(token):12").utf8)
        let original = Data([0x1b, 0x5b, 0x33, 0xc3]) + Data([0xa9]) + foreign + suffix
        let wire = Data([0x1b, 0x5b, 0x33, 0xc3]) + marker + Data([0xa9]) + foreign + suffix
        var decoder = MobileTmuxOutputDecoder(nonce: nonce)
        var outputs = wire.flatMap { decoder.decode(.bytes(Data([$0]))) }
        outputs += decoder.decode(.exited(0))
        let bytes = outputs.reduce(into: Data()) { result, output in
            if case .bytes(let data) = output { result.append(data) }
        }
        let geometries = outputs.compactMap { output -> MobileTmuxGeometry? in
            if case .geometry(let value) = output { return value }
            return nil
        }
        #expect(bytes == original)
        #expect(geometries.count == 1)
        #expect(geometries.first?.rows == 40)
    }

    @Test(arguments: [("off", 0), ("on", 1), ("3", 3), ("5", 5)])
    func privateGeometryFramesBecomeOrderedMetadata(_ status: String, _ statusRows: Int) async throws {
        let routes = MobileAttachmentTestRoutes()
        let process = MobileAttachmentTestPTY()
        let controller = Self.controller(routes, process)
        let id = try Self.attachID(await controller.prepareAttach(Self.attachRequest(), subscribed: true))
        let receipts = AsyncStream<MobileTmuxAttachmentEvent>.makeStream()
        await controller.activate(attachID: id) { receipts.continuation.yield($0); return true }
        let nonce = id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let marker = "\u{001e}UCPTY_GEOMETRY_\(nonce):120:40:\(status)\u{001f}"
        await process.emit(.bytes(Data(marker.utf8)))
        var events = receipts.stream.makeAsyncIterator()
        let first = try #require(await events.next())
        await controller.closeAll()
        #expect(first.sequence == 0)
        #expect(first.jsonObject["source_columns"] as? Int == 120)
        #expect(first.jsonObject["source_rows"] as? Int == 40)
        #expect(first.jsonObject["presentation_columns"] as? Int == 120)
        #expect(first.jsonObject["presentation_rows"] as? Int == 40 + statusRows)
        #expect(first.jsonObject["data"] == nil)
    }

    @Test func repeatedAttachKeepsItsIDAndPhysicalClient() async throws {
        let routes = MobileAttachmentTestRoutes()
        let process = MobileAttachmentTestPTY()
        let controller = Self.controller(routes, process)
        let request = Self.attachRequest()
        let first = try Self.payload(await controller.prepareAttach(request, subscribed: true))
        let second = try Self.payload(await controller.prepareAttach(request, subscribed: true))
        #expect(first["attach_id"] as? String == second["attach_id"] as? String)
        #expect(first["columns"] as? Int == 80)
        #expect(first["rows"] as? Int == 24)
        #expect(await process.starts == 1)
        await controller.closeAll()
        #expect(await process.closes == 1)
    }

    @Test func subscriptionsAndStrictParametersAreRequiredBeforeSpawn() async {
        let routes = MobileAttachmentTestRoutes()
        let process = MobileAttachmentTestPTY()
        let controller = Self.controller(routes, process)
        let request = Self.attachRequest()
        #expect(Self.code(await controller.prepareAttach(request, subscribed: false)) == "subscription_required")
        let invalidDimensions: [Any] = [true, false, 0, -1, 1001, 2.5, "80", NSNull(), Double.infinity]
        for value in invalidDimensions {
            var params = request.params
            params["columns"] = value
            #expect(Self.code(await controller.prepareAttach(Self.request("mobile.terminal.attach", params), subscribed: true)) == "invalid_params")
        }
        for value in ["", "surface:1", UUID().uuidString + " ", "{" + UUID().uuidString + "}"] {
            var params = request.params
            params["surface_id"] = value
            #expect(Self.code(await controller.prepareAttach(Self.request("mobile.terminal.attach", params), subscribed: true)) == "invalid_params")
        }
        #expect(await process.starts == 0)
        #expect(await routes.calls == 0)
    }

    @Test func pendingReservationsCountTowardTheFourClientLimit() async throws {
        let gate = AsyncStream<Void>.makeStream()
        let routes = MobileAttachmentTestRoutes(holdCall: 1, gate: gate.stream)
        var calls = routes.observedCalls.makeAsyncIterator()
        let controller = MobileTmuxAttachmentController(resolve: { workspace, surface, _ in try await routes.resolve(workspace, surface) }, makeProcess: { MobileAttachmentTestPTY() })
        let request = Self.attachRequest()
        let pending = Task { await controller.prepareAttach(request, subscribed: true) }
        #expect(await calls.next() == 1)
        for _ in 0..<3 {
            _ = try Self.payload(await controller.prepareAttach(Self.attachRequest(), subscribed: true))
        }
        #expect(Self.code(await controller.prepareAttach(Self.attachRequest(), subscribed: true)) == "attachment_limit")
        let duplicate = Task { await controller.prepareAttach(request, subscribed: true) }
        gate.continuation.yield(())
        gate.continuation.finish()
        let first = try Self.payload(await pending.value)
        let repeated = try Self.payload(await duplicate.value)
        #expect(first["attach_id"] as? String == repeated["attach_id"] as? String)
        await controller.closeAll()
    }

    @Test func anotherConnectionCannotUseAnAttachmentEvenWithTheSameClientID() async throws {
        let routes = MobileAttachmentTestRoutes()
        let ownerProcess = MobileAttachmentTestPTY()
        let otherProcess = MobileAttachmentTestPTY()
        let owner = Self.controller(routes, ownerProcess)
        let other = Self.controller(routes, otherProcess)
        let request = Self.attachRequest()
        let id = try Self.attachID(await owner.prepareAttach(request, subscribed: true))
        let otherID = try Self.attachID(await other.prepareAttach(request, subscribed: true))
        #expect(otherID != id)
        let common: [String: Any] = [
            "attach_id": id.uuidString,
            "client_id": request.params["client_id"]!,
            "data": Data("secret".utf8).base64EncodedString(),
            "columns": 90,
            "rows": 40,
        ]
        for method in ["mobile.terminal.pty_input", "mobile.terminal.pty_resize", "mobile.terminal.detach"] {
            #expect(Self.code(await other.handle(Self.request(method, common))) == "attachment_not_found")
        }
        #expect(await ownerProcess.writes.isEmpty)
        #expect(await ownerProcess.resizes.isEmpty)
        #expect(await ownerProcess.closes == 0)
        await other.closeAll()
        #expect(await ownerProcess.closes == 0)
        await owner.closeAll()
    }

    @Test func outputWaitsForActivationAndEachSendCompletesBeforeTheNextChunk() async throws {
        let routes = MobileAttachmentTestRoutes()
        let process = MobileAttachmentTestPTY()
        let controller = Self.controller(routes, process)
        let id = try Self.attachID(await controller.prepareAttach(Self.attachRequest(), subscribed: true))
        await process.emit(.bytes(Data([1])))
        await process.emit(.bytes(Data([2])))
        let receipts = AsyncStream<MobileTmuxAttachmentEvent>.makeStream()
        let firstReceipt = AsyncStream<Void>.makeStream()
        let sink = MobileAttachmentTestSink(receipts: receipts.continuation, gate: firstReceipt.stream)
        #expect(await sink.count == 0)
        await controller.activate(attachID: id) { await sink.send($0) }
        var events = receipts.stream.makeAsyncIterator()
        let first = try #require(await events.next())
        #expect(first.sequence == 0)
        #expect(first.jsonObject["data"] as? String == "AQ==")
        #expect(await sink.count == 1)
        firstReceipt.continuation.yield(())
        firstReceipt.continuation.finish()
        let second = try #require(await events.next())
        #expect(second.sequence == 1)
        #expect(second.jsonObject["data"] as? String == "Ag==")
        await controller.closeAll()
    }

    @Test func outputIsPrivateAndSequencesArePerAttachment() async throws {
        let routes = MobileAttachmentTestRoutes()
        let aProcess = MobileAttachmentTestPTY()
        let bProcess = MobileAttachmentTestPTY()
        let a = Self.controller(routes, aProcess)
        let b = Self.controller(routes, bProcess)
        let request = Self.attachRequest()
        let aID = try Self.attachID(await a.prepareAttach(request, subscribed: true))
        let bID = try Self.attachID(await b.prepareAttach(request, subscribed: true))
        let receivedA = AsyncStream<MobileTmuxAttachmentEvent>.makeStream()
        let receivedB = AsyncStream<MobileTmuxAttachmentEvent>.makeStream()
        await a.activate(attachID: aID) { receivedA.continuation.yield($0); return true }
        await b.activate(attachID: bID) { receivedB.continuation.yield($0); return true }
        await aProcess.emit(.bytes(Data("a".utf8)))
        await bProcess.emit(.bytes(Data("b".utf8)))
        var aEvents = receivedA.stream.makeAsyncIterator()
        var bEvents = receivedB.stream.makeAsyncIterator()
        let aEvent = try #require(await aEvents.next())
        let bEvent = try #require(await bEvents.next())
        #expect(aEvent.attachID == aID)
        #expect(bEvent.attachID == bID)
        #expect(aEvent.output == .bytes(Data("a".utf8)))
        #expect(bEvent.output == .bytes(Data("b".utf8)))
        #expect(aEvent.sequence == 0 && bEvent.sequence == 0)
        await a.closeAll()
        await b.closeAll()
    }

    @Test func inputIsStrictBase64AndBoundedAndResizeTargetsOnlyTheOwnedPTY() async throws {
        let routes = MobileAttachmentTestRoutes()
        let process = MobileAttachmentTestPTY()
        let controller = Self.controller(routes, process)
        let id = try Self.attachID(await controller.prepareAttach(Self.attachRequest(), subscribed: true))
        for encoded in ["", "%%%", "YQ==\n", "YR==", Data(repeating: 1, count: 65_537).base64EncodedString()] {
            #expect(Self.code(await controller.handle(Self.request("mobile.terminal.pty_input", ["attach_id": id.uuidString, "data": encoded]))) == "invalid_params")
        }
        let bytes = Data(repeating: 0x1B, count: 65_536)
        let input = try Self.payload(await controller.handle(Self.request("mobile.terminal.pty_input", ["attach_id": id.uuidString, "data": bytes.base64EncodedString()])))
        #expect(input["queued"] as? Bool == true)
        #expect(await process.writes == [bytes])
        #expect(Self.code(await controller.handle(Self.request("mobile.terminal.pty_resize", ["attach_id": id.uuidString, "columns": true, "rows": 10]))) == "invalid_params")
        let resize = try Self.payload(await controller.handle(Self.request("mobile.terminal.pty_resize", ["attach_id": id.uuidString, "columns": 1000, "rows": 1])))
        #expect(resize["columns"] as? Int == 1000)
        #expect(await process.resizes == [[1000, 1]])
        await controller.closeAll()
    }

    @Test(arguments: ["mobile.terminal.pty_input", "mobile.terminal.pty_resize", "revalidate"])
    func routeReplacementInvalidatesBeforeAnyFurtherOperation(_ method: String) async throws {
        let routes = MobileAttachmentTestRoutes()
        let process = MobileAttachmentTestPTY()
        let controller = Self.controller(routes, process)
        let id = try Self.attachID(await controller.prepareAttach(Self.attachRequest(), subscribed: true))
        await routes.replaceIdentity()
        if method == "revalidate" {
            await controller.revalidateAll()
        } else {
            #expect(Self.code(await controller.handle(Self.request(method, ["attach_id": id.uuidString, "data": "YQ==", "columns": 90, "rows": 30]))) == "attachment_not_found")
        }
        #expect(await process.writes.isEmpty)
        #expect(await process.resizes.isEmpty)
        #expect(await process.closes == 1)
        await controller.closeAll()
    }

    @Test func staleOutputIsNeverDeliveredAfterRouteInvalidation() async throws {
        let routes = MobileAttachmentTestRoutes()
        let process = MobileAttachmentTestPTY()
        var closures = process.observedCloses.makeAsyncIterator()
        let controller = Self.controller(routes, process)
        let id = try Self.attachID(await controller.prepareAttach(Self.attachRequest(), subscribed: true))
        await routes.replaceIdentity()
        await controller.activate(attachID: id) { _ in
            Issue.record("Output from an invalidated route was delivered")
            return true
        }
        await process.emit(.bytes(Data("stale".utf8)))
        #expect(await closures.next() == 1)
    }

    @Test(arguments: [1, 2])
    func cancellationCleansPendingReservationBeforeAndAfterSpawn(_ heldCall: Int) async throws {
        let gate = AsyncStream<Void>.makeStream()
        let routes = MobileAttachmentTestRoutes(holdCall: heldCall, gate: gate.stream)
        var calls = routes.observedCalls.makeAsyncIterator()
        let process = MobileAttachmentTestPTY()
        var closures = process.observedCloses.makeAsyncIterator()
        let controller = Self.controller(routes, process)
        let pending = Task { await controller.prepareAttach(Self.attachRequest(), subscribed: true) }
        for expected in 1...heldCall { #expect(await calls.next() == expected) }
        pending.cancel()
        #expect(await closures.next() == 1)
        gate.continuation.yield(())
        gate.continuation.finish()
        #expect(Self.code(await pending.value) == "attachment_not_found")
        #expect(await process.starts == heldCall - 1)
        #expect(await process.closes == 1)
        await controller.closeAll()
    }

    @Test func failedSendAndChildExitCloseTheirPrivatePTY() async throws {
        for rejectSend in [false, true] {
            let routes = MobileAttachmentTestRoutes()
            let process = MobileAttachmentTestPTY()
            var closures = process.observedCloses.makeAsyncIterator()
            let controller = Self.controller(routes, process)
            let id = try Self.attachID(await controller.prepareAttach(Self.attachRequest(), subscribed: true))
            let sent = AsyncStream<MobileTmuxAttachmentEvent>.makeStream()
            await controller.activate(attachID: id) { sent.continuation.yield($0); return !rejectSend }
            await process.emit(rejectSend ? .bytes(Data([1])) : .exited(66))
            var events = sent.stream.makeAsyncIterator()
            let event = try #require(await events.next())
            if !rejectSend {
                #expect(event.jsonObject["exit"] as? Bool == true)
                #expect(event.jsonObject["error"] as? String == "attach_failed")
            }
            #expect(await closures.next() == 1)
            #expect(Self.code(await controller.handle(Self.request("mobile.terminal.pty_input", ["attach_id": id.uuidString, "data": "YQ=="]))) == "attachment_not_found")
        }
    }

    @Test(arguments: [false, true])
    func resolverAndSpawnFailuresAreRedactedAndReleaseTheReservation(_ failResolution: Bool) async {
        let routes = MobileAttachmentTestRoutes()
        let process = MobileAttachmentTestPTY(failStart: true)
        let controller = MobileTmuxAttachmentController(resolve: { workspaceID, surfaceID, _ in
            if failResolution {
                throw MobileHostRPCError(code: "internal_error", message: "private-command")
            }
            return try await routes.resolve(workspaceID, surfaceID)
        }, makeProcess: { process })
        let result = await controller.prepareAttach(Self.attachRequest(), subscribed: true)
        #expect(Self.code(result) == "attach_failed")
        #expect(await process.closes == 1)
        #expect(await process.starts == (failResolution ? 0 : 1))
        if case .failure(let error) = result {
            #expect(!error.message.contains("private-command"))
        }
        await controller.closeAll()
    }

    @Test(arguments: [
        (MobileTmuxAttachError.locked, "locked"),
        (.targetUnavailable, "surface_unavailable"),
        (.targetChanged, "surface_unavailable"),
        (.legacyTerminal, "not_durable"),
        (.invalidSSHCredential, "invalid_ssh_credential"),
        (.missingTmux, "tmux_unavailable"),
        (.unsupportedTmux, "tmux_unsupported"),
        (.missingSession, "session_not_found"),
    ])
    func knownResolutionErrorsKeepTheirSafeActionableMessage(_ error: MobileTmuxAttachError, _ expectedCode: String) async {
        let process = MobileAttachmentTestPTY()
        let controller = MobileTmuxAttachmentController(resolve: { _, _, _ in throw error }, makeProcess: { process })
        let result = await controller.prepareAttach(Self.attachRequest(), subscribed: true)
        #expect(Self.code(result) == expectedCode)
        if case .failure(let failure) = result {
            #expect(failure.message == error.localizedDescription)
        }
        #expect(await process.starts == 0)
        #expect(await process.closes == 1)
    }

    @Test(arguments: [false, true])
    func framedRPCEnforcesAuthorizationOwnershipAndAttachReplyBeforeOutput(_ replaceSubscription: Bool) async throws {
        let routes = MobileAttachmentTestRoutes()
        let ownerProcess = MobileAttachmentTestPTY(initialOutput: Data([0x1B, 0x5B, 0x48]))
        let otherProcess = MobileAttachmentTestPTY()
        var ownerCloses = ownerProcess.observedCloses.makeAsyncIterator()
        let ownerSocket = try await MobileAttachmentTestSocket.connect()
        let otherSocket = try await MobileAttachmentTestSocket.connect()
        let owner = Self.connection(socket: ownerSocket, controller: Self.controller(routes, ownerProcess))
        let other = Self.connection(socket: otherSocket, controller: Self.controller(routes, otherProcess))
        await owner.start()
        await other.start()
        do {
            try await ownerSocket.send(Self.frame("subscribe", method: "mobile.events.subscribe", params: ["stream_id": "events", "topics": ["terminal.pty"]]))
            let subscription = try Self.object(await ownerSocket.nextFrame())
            #expect(subscription["id"] as? String == "subscribe")
            #expect(subscription["ok"] as? Bool == true)

            let request = Self.attachRequest()
            try await ownerSocket.send(Self.frame("attach", method: request.method, params: request.params))
            // The fake yields output inside start(), before prepareAttach can return.
            let reply = try Self.object(await ownerSocket.nextFrame())
            #expect(reply["id"] as? String == "attach")
            #expect(reply["ok"] as? Bool == true)
            #expect(reply["kind"] == nil)
            let result = try #require(reply["result"] as? [String: Any])
            let attachID = try #require(result["attach_id"] as? String)
            let pushed = try Self.object(await ownerSocket.nextFrame())
            #expect(pushed["topic"] as? String == "terminal.pty")
            let event = try #require(pushed["payload"] as? [String: Any])
            #expect(event["attach_id"] as? String == attachID)
            #expect(event["data"] as? String == "G1tI")
            #expect(event["seq"] as? Int == 0)

            try await otherSocket.send(Self.frame("denied", method: request.method, params: request.params))
            let denied = try Self.object(await otherSocket.nextFrame())
            #expect((denied["error"] as? [String: Any])?["code"] as? String == "unauthorized")
            #expect(await otherProcess.starts == 0)

            try await otherSocket.send(Self.frame("foreign", method: "mobile.terminal.pty_input", params: [
                "attach_id": attachID, "client_id": request.params["client_id"]!, "data": "YQ==",
            ]))
            let foreign = try Self.object(await otherSocket.nextFrame())
            #expect((foreign["error"] as? [String: Any])?["code"] as? String == "attachment_not_found")
            #expect(await ownerProcess.writes.isEmpty)
            await other.close(reason: "isolated integration test complete")
            #expect(await ownerProcess.closes == 0)
            if replaceSubscription {
                try await ownerSocket.send(Self.frame("replace", method: "mobile.events.subscribe", params: ["stream_id": "events", "topics": ["workspace.updated"]]))
                let replacement = try Self.object(await ownerSocket.nextFrame())
                #expect(replacement["id"] as? String == "replace")
                #expect(replacement["ok"] as? Bool == true)
                #expect(await ownerProcess.closes == 1)
            }
            await owner.close(reason: "isolated integration test complete")
            #expect(await ownerCloses.next() == 1)
            await ownerSocket.close()
            await otherSocket.close()
        } catch {
            await owner.close(reason: "isolated integration test failed")
            await other.close(reason: "isolated integration test failed")
            await ownerSocket.close()
            await otherSocket.close()
            throw error
        }
    }

    private static func connection(socket: MobileAttachmentTestSocket, controller: MobileTmuxAttachmentController) -> MobileHostConnection {
        MobileHostConnection(
            id: UUID(), connection: socket.serverConnection, tmux: controller,
            authorizeRequest: { request in
                if request.id as? String == "denied" {
                    return .failure(MobileHostRPCError(code: "unauthorized", message: "Acceso denegado."))
                }
                return nil
            },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in
                Issue.record("A tmux RPC escaped its connection-owned dispatcher")
                return .failure(MobileHostRPCError(code: "method_not_found", message: "Método no disponible."))
            },
            onClose: { _ in }
        )
    }

    private static func frame(_ id: String, method: String, params: [String: Any]) throws -> Data {
        try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params]))
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func controller(_ routes: MobileAttachmentTestRoutes, _ process: MobileAttachmentTestPTY) -> MobileTmuxAttachmentController {
        MobileTmuxAttachmentController(resolve: { workspace, surface, _ in try await routes.resolve(workspace, surface) }, makeProcess: { process })
    }

    private static func attachRequest() -> MobileHostRPCRequest {
        request("mobile.terminal.attach", ["workspace_id": UUID().uuidString, "surface_id": UUID().uuidString, "columns": 80, "rows": 24, "client_id": UUID().uuidString])
    }

    private static func request(_ method: String, _ params: [String: Any]) -> MobileHostRPCRequest {
        MobileHostRPCRequest(id: 1, method: method, params: params, auth: nil)
    }

    private static func payload(_ result: MobileHostRPCResult) throws -> [String: Any] {
        guard case .ok(let value) = result else {
            Issue.record("Expected successful attachment RPC")
            throw MobilePTYProcessError.invalidRequest
        }
        return try #require(value as? [String: Any])
    }

    private static func attachID(_ result: MobileHostRPCResult) throws -> UUID {
        let payload = try payload(result)
        return try #require((payload["attach_id"] as? String).flatMap(UUID.init(uuidString:)))
    }

    private static func code(_ result: MobileHostRPCResult) -> String? {
        guard case .failure(let error) = result else { return nil }
        return error.code
    }
}

private actor MobileAttachmentTestRoutes {
    private let holdCall: Int?
    private let gate: AsyncStream<Void>?
    private var generation = UUID()
    private let recordID = UUID()
    private let callEvents = AsyncStream<Int>.makeStream()
    nonisolated var observedCalls: AsyncStream<Int> { callEvents.stream }
    private(set) var calls = 0

    init(holdCall: Int? = nil, gate: AsyncStream<Void>? = nil) {
        self.holdCall = holdCall
        self.gate = gate
    }

    func resolve(_ workspaceID: UUID, _ surfaceID: UUID) async throws -> MobileTmuxAttachPlan {
        calls += 1
        let thisCall = calls
        callEvents.continuation.yield(thisCall)
        if thisCall == holdCall, let gate {
            for await _ in gate { break }
        }
        let object = ObjectIdentifier(NSObject.self)
        return MobileTmuxAttachPlan(
            workspaceID: workspaceID, surfaceID: surfaceID, command: "private-command",
            identity: .init(
                tabManager: object, workspace: object, panel: object, surface: object,
                surfaceGeneration: generation, profileIdentity: nil,
                target: .local(recordID: recordID, binding: UniConnectLocalTmuxBinding(name: "test", socketName: "test")!)
            )
        )
    }

    func replaceIdentity() { generation = UUID() }
}

private actor MobileAttachmentTestPTY: MobilePTYRunning {
    private let output = AsyncStream<MobilePTYOutput>.makeStream(bufferingPolicy: .bufferingOldest(32))
    private let closeEvents = AsyncStream<Int>.makeStream()
    private let failStart: Bool
    private let initialOutput: Data?
    nonisolated var observedCloses: AsyncStream<Int> { closeEvents.stream }
    private(set) var starts = 0
    private(set) var closes = 0
    private(set) var writes: [Data] = []
    private(set) var resizes: [[Int]] = []

    init(failStart: Bool = false, initialOutput: Data? = nil) {
        self.failStart = failStart
        self.initialOutput = initialOutput
    }

    func start(command: String, columns: Int, rows: Int) throws -> AsyncStream<MobilePTYOutput> {
        guard closes == 0 else { throw MobilePTYProcessError.notRunning }
        starts += 1
        if failStart { throw MobilePTYProcessError.system(5) }
        if let initialOutput { output.continuation.yield(.bytes(initialOutput)) }
        return output.stream
    }

    func write(_ data: Data) throws {
        guard closes == 0 else { throw MobilePTYProcessError.notRunning }
        writes.append(data)
    }

    func resize(columns: Int, rows: Int) throws {
        guard closes == 0 else { throw MobilePTYProcessError.notRunning }
        resizes.append([columns, rows])
    }

    func close() {
        guard closes == 0 else { return }
        closes += 1
        output.continuation.finish()
        closeEvents.continuation.yield(closes)
    }

    func emit(_ event: MobilePTYOutput) { output.continuation.yield(event) }
}

private actor MobileAttachmentTestSink {
    let receipts: AsyncStream<MobileTmuxAttachmentEvent>.Continuation
    let gate: AsyncStream<Void>
    private(set) var count = 0

    init(receipts: AsyncStream<MobileTmuxAttachmentEvent>.Continuation, gate: AsyncStream<Void>) {
        self.receipts = receipts
        self.gate = gate
    }

    func send(_ event: MobileTmuxAttachmentEvent) async -> Bool {
        count += 1
        receipts.yield(event)
        if count == 1 {
            for await _ in gate { break }
        }
        return true
    }
}

/// A CI-only loopback pair, with actual framing and no production listener or terminal process.
private actor MobileAttachmentTestSocket {
    nonisolated let serverConnection: NWConnection
    private let client: NWConnection
    private let listener: NWListener
    private var buffer = Data()
    private var frames: [Data] = []

    private init(serverConnection: NWConnection, client: NWConnection, listener: NWListener) {
        self.serverConnection = serverConnection
        self.client = client
        self.listener = listener
    }

    static func connect() async throws -> MobileAttachmentTestSocket {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        let listenerReady = AsyncThrowingStream<Void, Error>.makeStream()
        let accepted = AsyncStream<NWConnection>.makeStream(bufferingPolicy: .bufferingOldest(1))
        // Network.framework requires a dispatch queue for callback delivery; state lives in the actor.
        let queue = DispatchQueue(label: "uniconnect.tests.mobile-tmux-loopback")
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                listenerReady.continuation.yield(())
                listenerReady.continuation.finish()
            case .failed(let error):
                listenerReady.continuation.finish(throwing: error)
            case .cancelled:
                listenerReady.continuation.finish(throwing: CancellationError())
            default: break
            }
        }
        listener.newConnectionHandler = { connection in
            accepted.continuation.yield(connection)
            accepted.continuation.finish()
        }
        listener.start(queue: queue)
        do {
            for try await _ in listenerReady.stream { break }
            let port = try #require(listener.port)
            let client = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
            let clientReady = AsyncThrowingStream<Void, Error>.makeStream()
            client.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    clientReady.continuation.yield(())
                    clientReady.continuation.finish()
                case .failed(let error):
                    clientReady.continuation.finish(throwing: error)
                case .cancelled:
                    clientReady.continuation.finish(throwing: CancellationError())
                default: break
                }
            }
            client.start(queue: queue)
            do {
                for try await _ in clientReady.stream { break }
                var connections = accepted.stream.makeAsyncIterator()
                let server = try #require(await connections.next())
                return MobileAttachmentTestSocket(serverConnection: server, client: client, listener: listener)
            } catch {
                client.cancel()
                throw error
            }
        } catch {
            listener.cancel()
            throw error
        }
    }

    func send(_ frame: Data) async throws {
        let client = client
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                client.send(content: frame, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                })
            }
        } onCancel: {
            client.cancel()
        }
    }

    func nextFrame() async throws -> Data {
        while frames.isEmpty {
            let client = client
            let data: Data = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    client.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let data, !data.isEmpty { continuation.resume(returning: data) }
                        else if complete { continuation.resume(throwing: MobilePTYProcessError.notRunning) }
                        else { continuation.resume(returning: Data()) }
                    }
                }
            } onCancel: {
                client.cancel()
            }
            buffer.append(data)
            frames.append(contentsOf: try MobileSyncFrameCodec.decodeFrames(from: &buffer))
        }
        return frames.removeFirst()
    }

    func close() {
        client.cancel()
        serverConnection.cancel()
        listener.cancel()
    }
}
