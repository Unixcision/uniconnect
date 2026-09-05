import Foundation
import Testing
@testable import UniConnectClaudeBridge

@Suite("Claude bridge remote script execution")
struct ClaudeBridgeRemoteScriptExecutionTests {
    @Test("Registration is idempotent and cleanup restores foreign settings byte for byte")
    func registerTwiceThenUnregister() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("uniconnect-bridge-script-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: home.appendingPathComponent(".claude", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: home) }

        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        let original = Data("""
        {
          "theme": "dark",
          "hooks": {
            "Stop": [
              {
                "matcher": "",
                "hooks": [
                  {"type": "command", "command": "printf foreign", "timeout": 1}
                ]
              }
            ]
          },
          "custom": {"keep": true}
        }
        """.utf8)
        try original.write(to: settingsURL)

        let route = ClaudeBridgeRoute(
            id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            workspaceID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            surfaceID: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
            credentialID: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
            hostLabel: "fixture.invalid",
            workspaceName: "Fixture",
            windowName: "Window",
            tmuxSession: "uc-fixture"
        )
        let connectionID = UUID()
        let plan = ClaudeBridgeRemoteIntegration.connectionPlan(
            route: route,
            installationID: String(repeating: "a", count: 32),
            localListenerPort: 49_321,
            connectionID: connectionID
        )

        try runRemoteShell(plan.remoteSetupCommand, home: home)
        let firstRegistration = try Data(contentsOf: settingsURL)
        let lifecycleLockURL = home
            .appendingPathComponent(".uniconnect/claude-bridge/v1/lifecycle.lock")
        let lifecycleLockAttributes = try fileManager.attributesOfItem(
            atPath: lifecycleLockURL.path
        )
        #expect(lifecycleLockAttributes[.posixPermissions] as? Int == 0o600)
        let firstDocument = try #require(
            JSONSerialization.jsonObject(with: firstRegistration) as? [String: Any]
        )
        let hooks = try #require(firstDocument["hooks"] as? [String: Any])
        #expect((hooks["Stop"] as? [[String: Any]])?.count == 2)
        #expect((hooks["Notification"] as? [[String: Any]])?.count == 1)
        #expect((hooks["UserPromptSubmit"] as? [[String: Any]])?.count == 1)
        #expect((hooks["SessionStart"] as? [[String: Any]])?.count == 1)
        #expect(firstRegistration.range(of: Data("printf foreign".utf8)) != nil)

        try runRemoteShell(plan.remoteSetupCommand, home: home)
        #expect(try Data(contentsOf: settingsURL) == firstRegistration)

        let routeFile = home
            .appendingPathComponent(".uniconnect/claude-bridge/v1/installations")
            .appendingPathComponent(String(repeating: "a", count: 32))
            .appendingPathComponent("\(route.id.uuidString.lowercased()).route.json")
        var routeDocument = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: routeFile)) as? [String: Any]
        )
        let expectedSocket = ClaudeBridgeRemoteIntegration.remoteForwardSocketPath(
            for: route.id,
            installationID: String(repeating: "a", count: 32),
            connectionID: connectionID
        )
        #expect(routeDocument["socket_path"] as? String == expectedSocket)
        #expect(routeDocument["port"] == nil)
        let notify = home.appendingPathComponent(".uniconnect/claude-bridge/v1/notify.py")
        #expect(
            try candidateEndpoint(
                notify: notify,
                home: home,
                tmuxSession: route.tmuxSession
            ) == expectedSocket
        )

        // A route written by the previous TCP-forwarding version remains readable
        // while that older SSH connection is alive, but registration never writes it.
        routeDocument.removeValue(forKey: "socket_path")
        routeDocument.removeValue(forKey: "connection_id")
        routeDocument["port"] = 49_321
        try JSONSerialization.data(withJSONObject: routeDocument).write(to: routeFile)
        #expect(
            try candidateEndpoint(
                notify: notify,
                home: home,
                tmuxSession: route.tmuxSession
            ) == "49321"
        )

        routeDocument["socket_path"] = [
            "/tmp/ucb-",
            String(repeating: "f", count: 32),
            "-",
            String(repeating: "e", count: 32),
            ".sock",
        ].joined()
        try JSONSerialization.data(withJSONObject: routeDocument).write(to: routeFile)
        #expect(
            try candidateEndpoint(
                notify: notify,
                home: home,
                tmuxSession: route.tmuxSession
            ) == "invalid"
        )

        // A valid legacy Unix route is still recognized independently of the new
        // connection-scoped format; malformed new generations cannot downgrade.
        let legacySocket = ClaudeBridgeRemoteIntegration.remoteForwardSocketPath(
            for: route.id,
            installationID: String(repeating: "a", count: 32)
        )
        routeDocument["socket_path"] = legacySocket
        try JSONSerialization.data(withJSONObject: routeDocument).write(to: routeFile)
        #expect(
            try candidateEndpoint(notify: notify, home: home, tmuxSession: route.tmuxSession)
                == legacySocket
        )
        routeDocument["connection_id"] = "invalid-generation"
        routeDocument.removeValue(forKey: "socket_path")
        try JSONSerialization.data(withJSONObject: routeDocument).write(to: routeFile)
        #expect(
            try candidateEndpoint(notify: notify, home: home, tmuxSession: route.tmuxSession)
                == "invalid"
        )
        routeDocument["connection_id"] = connectionID.uuidString.lowercased()
        routeDocument["socket_path"] = legacySocket
        try JSONSerialization.data(withJSONObject: routeDocument).write(to: routeFile)
        #expect(
            try candidateEndpoint(notify: notify, home: home, tmuxSession: route.tmuxSession)
                == "invalid"
        )
        routeDocument["socket_path"] = expectedSocket
        routeDocument.removeValue(forKey: "port")
        try JSONSerialization.data(withJSONObject: routeDocument).write(to: routeFile)

        let remoteSocketURL = URL(fileURLWithPath: expectedSocket)
        defer { try? fileManager.removeItem(at: remoteSocketURL) }
        try Data("stale socket placeholder".utf8).write(to: remoteSocketURL)
        try runRemoteShell(plan.remoteCleanupCommand, home: home)
        #expect(try Data(contentsOf: settingsURL) == original)
        #expect(!fileManager.fileExists(atPath: routeFile.path))
        #expect(!fileManager.fileExists(atPath: remoteSocketURL.path))
    }

    @Test("Invalid or ambiguous hook settings remain byte-for-byte untouched")
    func invalidHookSettingsAreNeverMutated() throws {
        let fixtures = [
            Data(#"{"hooks":{"Stop":[{"matcher":"","hooks":"not-an-array"}]}}"#.utf8),
            Data(#"{"theme":"dark","theme":"light"}"#.utf8),
        ]
        let fileManager = FileManager.default

        for (index, original) in fixtures.enumerated() {
            let home = fileManager.temporaryDirectory.appendingPathComponent(
                "uniconnect-bridge-invalid-\(index)-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: home.appendingPathComponent(".claude", isDirectory: true),
                withIntermediateDirectories: true
            )
            defer { try? fileManager.removeItem(at: home) }
            let settingsURL = home.appendingPathComponent(".claude/settings.json")
            try original.write(to: settingsURL)
            let plan = ClaudeBridgeRemoteIntegration.connectionPlan(
                route: BridgeTestMessages.route(),
                installationID: String(repeating: "b", count: 32),
                localListenerPort: 49_323
            )

            try runRemoteShell(plan.remoteSetupCommand, home: home)

            #expect(try Data(contentsOf: settingsURL) == original)
        }
    }

    @Test("A completion hook remains non-blocking when the Mac app is closed")
    func hookWithoutLoopbackListenerReturnsSuccessQuickly() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("uniconnect-bridge-offline-\(UUID().uuidString)", isDirectory: true)
        let bin = home.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(
            at: home.appendingPathComponent(".claude", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }

        let tmux = bin.appendingPathComponent("tmux")
        try Data("#!/bin/sh\nprintf 'uc-fixture\\n'\n".utf8).write(to: tmux)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmux.path)

        let route = ClaudeBridgeRoute(
            id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            workspaceID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            surfaceID: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
            credentialID: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
            hostLabel: "fixture.invalid",
            workspaceName: "Fixture",
            windowName: "Window",
            tmuxSession: "uc-fixture"
        )
        let plan = ClaudeBridgeRemoteIntegration.connectionPlan(
            route: route,
            installationID: String(repeating: "a", count: 32),
            localListenerPort: 49_321
        )
        try runRemoteShell(plan.remoteSetupCommand, home: home)

        let notify = home.appendingPathComponent(".uniconnect/claude-bridge/v1/notify.py")
        let process = Process()
        process.executableURL = notify
        process.arguments = ["hook", "stop"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["PATH"] = "\(bin.path):/usr/bin:/bin"
        environment["TMUX_PANE"] = "%7"
        process.environment = environment
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let startedAt = Date()
        try process.run()
        input.fileHandleForWriting.write(Data(#"{"hook_event_name":"Stop","session_id":"55555555-5555-4555-8555-555555555555","cwd":"/srv/app"}"#.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(Date().timeIntervalSince(startedAt) < 2.5)
        let journalURL = home
            .appendingPathComponent(".uniconnect/claude-bridge/v1/installations")
            .appendingPathComponent(String(repeating: "a", count: 32))
            .appendingPathComponent("\(route.id.uuidString.lowercased()).session.json")
        let journal = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any]
        )
        #expect(journal["activity_state"] as? String == "idle")
        #expect(journal["session_id"] as? String == "55555555-5555-4555-8555-555555555555")
    }

    @Test("A submitted prompt updates only the private journal")
    func promptHookDoesNotPersistOrRelayPromptContent() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("uniconnect-bridge-prompt-\(UUID().uuidString)", isDirectory: true)
        let bin = home.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(
            at: home.appendingPathComponent(".claude", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }

        let tmux = bin.appendingPathComponent("tmux")
        try Data("#!/bin/sh\nprintf 'uc-fixture\\n'\n".utf8).write(to: tmux)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmux.path)

        let route = ClaudeBridgeRoute(
            id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            workspaceID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            surfaceID: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
            credentialID: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
            hostLabel: "fixture.invalid",
            workspaceName: "Fixture",
            windowName: "Window",
            tmuxSession: "uc-fixture"
        )
        let installationID = String(repeating: "a", count: 32)
        let plan = ClaudeBridgeRemoteIntegration.connectionPlan(
            route: route,
            installationID: installationID,
            localListenerPort: 49_321
        )
        try runRemoteShell(plan.remoteSetupCommand, home: home)

        let notify = home.appendingPathComponent(".uniconnect/claude-bridge/v1/notify.py")
        let process = Process()
        process.executableURL = notify
        process.arguments = ["hook", "prompt"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["PATH"] = "\(bin.path):/usr/bin:/bin"
        environment["TMUX_PANE"] = "%7"
        process.environment = environment
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        input.fileHandleForWriting.write(Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"55555555-5555-4555-8555-555555555555","cwd":"/srv/app","prompt":"do not persist this private prompt"}"#.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        let journalURL = home
            .appendingPathComponent(".uniconnect/claude-bridge/v1/installations")
            .appendingPathComponent(installationID)
            .appendingPathComponent("\(route.id.uuidString.lowercased()).session.json")
        let journalData = try Data(contentsOf: journalURL)
        let journal = try #require(
            JSONSerialization.jsonObject(with: journalData) as? [String: Any]
        )
        #expect(journal["activity_state"] as? String == "running")
        #expect(journal["session_id"] as? String == "55555555-5555-4555-8555-555555555555")
        #expect(journalData.range(of: Data("do not persist this private prompt".utf8)) == nil)
        #expect(journal["prompt"] == nil)
    }

    @Test("The first replacement forward works with an orphaned socket and retains the Claude identity")
    func replacementForwardWithOrphanedSocket() throws {
        let result = try runForwardReplacementFixture(keepPreviousConnectionAlive: false)
        #expect(result["replacement_bound_first_time"] == true)
        #expect(result["previous_socket_was_orphaned"] == true)
        #expect(result["replacement_enrolled"] == true)
        #expect(result["published_before_signed_hello"] == true)
        #expect(result["hook_reached_replacement"] == true)
        #expect(result["stable_token_and_session"] == true)
    }

    @Test("An overlapping replacement preserves the old live socket and routes hooks to the new connection")
    func replacementForwardWhilePreviousConnectionIsAlive() throws {
        let result = try runForwardReplacementFixture(keepPreviousConnectionAlive: true)
        #expect(result["replacement_bound_first_time"] == true)
        #expect(result["previous_socket_still_live"] == true)
        #expect(result["replacement_enrolled"] == true)
        #expect(result["hook_reached_replacement"] == true)
        #expect(result["stable_token_and_session"] == true)
        #expect(result["no_hook_sent_to_previous_connection"] == true)
        #expect(result["superseded_registration_kept_replacement"] == true)
        #expect(result["offline_old_registration_kept_replacement"] == true)
        #expect(result["rejected_registration_did_not_send_hello"] == true)
    }

    @Test("A lost enrollment acknowledgement is retried idempotently without another SSH connection")
    func replacementForwardRetriesLostEnrollmentAcknowledgement() throws {
        let result = try runForwardReplacementFixture(
            keepPreviousConnectionAlive: true,
            dropFirstReplacementAcknowledgement: true
        )
        #expect(result["replacement_enrolled"] == true)
        #expect(result["lost_ack_retried_same_enrollment"] == true)
        #expect(result["hook_reached_replacement"] == true)
        #expect(result["stable_token_and_session"] == true)
    }

    @Test("Enrollment tolerates startup latency beyond the short completion-hook deadline")
    func replacementWaitsForSlowEnrollmentAcknowledgement() throws {
        let result = try runForwardReplacementFixture(
            keepPreviousConnectionAlive: true,
            enrollmentAcknowledgementDelay: 1.2
        )
        #expect(result["slow_enrollment_acknowledgement_received"] == true)
        #expect(result["published_before_signed_hello"] == true)
        #expect(result["hook_reached_replacement"] == true)
    }

    @Test("Invalid hook settings never produce a ready confirmation even when enrollment is accepted")
    func unavailableIntegrationDoesNotSendReadyHello() throws {
        let result = try runForwardReplacementFixture(
            keepPreviousConnectionAlive: true,
            invalidateSettingsAfterReplacement: true
        )
        #expect(result["unready_registration_did_not_send_hello"] == true)
        #expect(result["invalid_settings_left_untouched"] == true)
    }

    @Test("An enrollment waiting for its ACK does not block another route's hooks or registration")
    func slowRegistrationDoesNotBlockOtherRoutes() throws {
        let result = try runForwardReplacementFixture(
            keepPreviousConnectionAlive: true,
            verifyParallelRouteProgress: true
        )
        #expect(result["other_route_hook_completed_before_ack"] == true)
        #expect(result["other_route_registration_completed_before_ack"] == true)
        #expect(result["published_before_signed_hello"] == true)
    }

    @Test("Unregistering during an enrollment ACK prevents route and token resurrection")
    func unregisterDuringEnrollmentDoesNotResurrectRoute() throws {
        let result = try runForwardReplacementFixture(
            keepPreviousConnectionAlive: true,
            unregisterDuringEnrollment: true
        )
        #expect(result["unregister_completed_before_ack"] == true)
        #expect(result["unregister_during_ack_did_not_resurrect"] == true)
        #expect(result["revoked_registration_did_not_send_hello"] == true)
    }

    /// Exercises generated setup and real hooks against bounded Unix-socket servers.
    private func runForwardReplacementFixture(
        keepPreviousConnectionAlive: Bool,
        dropFirstReplacementAcknowledgement: Bool = false,
        enrollmentAcknowledgementDelay: TimeInterval = 0,
        invalidateSettingsAfterReplacement: Bool = false,
        verifyParallelRouteProgress: Bool = false,
        unregisterDuringEnrollment: Bool = false
    ) throws -> [String: Bool] {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent(
            "uniconnect-bridge-replacement-\(UUID().uuidString)", isDirectory: true
        )
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }
        let installationID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let route = BridgeTestMessages.route(tmuxSession: "uc-replacement-fixture")
        let previousConnectionID = UUID()
        let replacementConnectionID = UUID()
        let previous = ClaudeBridgeRemoteIntegration.connectionPlan(
            route: route,
            installationID: installationID,
            localListenerPort: 49_321,
            connectionID: previousConnectionID
        )
        let replacement = ClaudeBridgeRemoteIntegration.connectionPlan(
            route: route,
            installationID: installationID,
            localListenerPort: 49_321,
            connectionID: replacementConnectionID
        )
        let previousSocket = ClaudeBridgeRemoteIntegration.remoteForwardSocketPath(
            for: route.id, installationID: installationID, connectionID: previousConnectionID
        )
        let replacementSocket = ClaudeBridgeRemoteIntegration.remoteForwardSocketPath(
            for: route.id, installationID: installationID, connectionID: replacementConnectionID
        )
        let parallelRoute = BridgeTestMessages.route(tmuxSession: "uc-parallel-fixture")
        let parallelConnectionID = UUID()
        let parallelSocket = ClaudeBridgeRemoteIntegration.remoteForwardSocketPath(
            for: parallelRoute.id, installationID: installationID, connectionID: parallelConnectionID
        )
        let parallel = ClaudeBridgeRemoteIntegration.connectionPlan(
            route: parallelRoute,
            installationID: installationID,
            localListenerPort: 49_321,
            connectionID: parallelConnectionID
        )
        // These are exact, unique fixture paths; a failed subprocess cannot leave
        // orphan sockets in the shared /tmp directory.
        defer {
            try? fileManager.removeItem(atPath: previousSocket)
            try? fileManager.removeItem(atPath: replacementSocket)
            try? fileManager.removeItem(atPath: parallelSocket)
        }
        let fixture: [String: Any] = [
            "previous_setup": previous.remoteSetupCommand,
            "replacement_setup": replacement.remoteSetupCommand,
            "replacement_cleanup": replacement.remoteCleanupCommand,
            "previous_socket": previousSocket,
            "replacement_socket": replacementSocket,
            "installation_id": installationID,
            "route_id": route.id.uuidString.lowercased(),
            "replacement_connection_id": replacementConnectionID.uuidString.lowercased(),
            "tmux_session": route.tmuxSession,
            "keep_previous_alive": keepPreviousConnectionAlive,
            "drop_first_replacement_ack": dropFirstReplacementAcknowledgement,
            "enrollment_ack_delay_seconds": enrollmentAcknowledgementDelay,
            "invalidate_settings_after_replacement": invalidateSettingsAfterReplacement,
            "verify_parallel_route_progress": verifyParallelRouteProgress,
            "unregister_during_enrollment": unregisterDuringEnrollment,
            "parallel_route_id": parallelRoute.id.uuidString.lowercased(),
            "parallel_socket": parallelSocket,
            "parallel_setup": parallel.remoteSetupCommand,
            "parallel_tmux_session": parallelRoute.tmuxSession,
        ]
        let fixtureURL = home.appendingPathComponent("fixture.json")
        try JSONSerialization.data(withJSONObject: fixture).write(to: fixtureURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", Self.forwardReplacementHarness, fixtureURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["PATH"] = "/usr/bin:/bin"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Bool])
    }

    private static let forwardReplacementHarness = #"""
import hashlib, hmac, json, os, queue, runpy, select, socket, stat, subprocess, sys, threading

with open(sys.argv[1], "rt", encoding="utf-8") as source:
    fixture = json.load(source)

class Endpoint:
    def __init__(self, path, drop_first_response=False, first_response_delay=0,
                 route_id=None, enrollment_gate=None):
        self.path = path
        self.route_id = route_id or fixture["route_id"]
        self.route_path = os.path.join(directory, self.route_id + ".route.json")
        self.token_path = os.path.join(directory, self.route_id + ".token")
        self.frames = queue.Queue()
        self.response = {"accepted": True, "duplicate": False}
        self.drop_first_response = drop_first_response
        self.first_response_delay = first_response_delay
        self.hello_publication_checks = []
        self.first_enrollment_seen = threading.Event()
        self.enrollment_gate = enrollment_gate
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(path)
        self.listener.listen(8)
        self.stop_read, self.stop_write = socket.socketpair()
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()
        self.closed = False

    def serve(self):
        while True:
            ready, _, _ = select.select([self.listener, self.stop_read], [], [], 20)
            if not ready or self.stop_read in ready:
                return
            client, _ = self.listener.accept()
            with client:
                client.settimeout(2)
                payload = b""
                while len(payload) <= 16384 and not payload.endswith(b"\n"):
                    chunk = client.recv(1024)
                    if not chunk:
                        break
                    payload += chunk
                if payload:
                    message = json.loads(payload.decode("utf-8"))
                    if message.get("message") == "hello":
                        try:
                            with open(self.route_path, "rt", encoding="utf-8") as source:
                                published = json.load(source)
                            committed = (published["socket_path"] == self.path
                                         and published["connection_id"] == message.get("connection_id"))
                        except Exception:
                            committed = False
                        # Observe publication when the hello arrives, not after
                        # register returns; the latter would miss wrong ordering.
                        self.hello_publication_checks.append(committed)
                    self.frames.put(message)
                    if message.get("message") == "enroll":
                        self.first_enrollment_seen.set()
                        if self.enrollment_gate is not None:
                            assert self.enrollment_gate.wait(timeout=4)
                    if self.first_response_delay:
                        # Fault injection: real ACK latency above the hook's
                        # 0.75 s budget, not a sleep to wait for state to settle.
                        threading.Event().wait(self.first_response_delay)
                        self.first_response_delay = 0
                    if self.drop_first_response:
                        self.drop_first_response = False
                    elif self.response is not None:
                        try:
                            client.sendall(json.dumps(self.response).encode("utf-8") + b"\n")
                        except OSError:
                            pass

    def close(self):
        if self.closed:
            return
        self.closed = True
        self.stop_write.sendall(b"x")
        self.thread.join(timeout=3)
        assert not self.thread.is_alive()
        self.listener.close()
        self.stop_read.close()
        self.stop_write.close()

def setup(command, timeout=12):
    subprocess.run(["/bin/sh", "-c", command], check=True, timeout=timeout)

home = os.environ["HOME"]
notify = os.path.join(home, ".uniconnect", "claude-bridge", "v1", "notify.py")
directory = os.path.join(home, ".uniconnect", "claude-bridge", "v1", "installations", fixture["installation_id"])
route_path = os.path.join(directory, fixture["route_id"] + ".route.json")
token_path = os.path.join(directory, fixture["route_id"] + ".token")
journal_path = os.path.join(directory, fixture["route_id"] + ".session.json")
bin_path = os.path.join(home, "bin")
os.makedirs(bin_path)
tmux_path = os.path.join(bin_path, "tmux")
with open(tmux_path, "wt", encoding="utf-8") as tmux:
    tmux.write("#!/bin/sh\nprintf '%s\\n' \"$UC_TEST_TMUX_SESSION\"\n")
os.chmod(tmux_path, 0o700)
hook_environment = dict(os.environ, PATH=bin_path + ":/usr/bin:/bin", TMUX_PANE="%7",
                        UC_TEST_TMUX_SESSION=fixture["tmux_session"])
session_id = "55555555-5555-4555-8555-555555555555"
hook_input = json.dumps({
    "hook_event_name": "Stop", "session_id": session_id, "cwd": "/srv/app",
}).encode("utf-8")

def hook(tmux_session=None, timeout=6):
    environment = hook_environment if tmux_session is None else dict(
        hook_environment, UC_TEST_TMUX_SESSION=tmux_session
    )
    subprocess.run([notify, "hook", "stop"], input=hook_input,
                   env=environment, check=True, timeout=timeout)

def require_published_hello(endpoint, expected_count=1):
    hello = endpoint.frames.get(timeout=2)
    assert hello["message"] == "hello"
    assert hello["route_id"] == endpoint.route_id
    assert "token" not in hello and "integration_ready" not in hello
    with open(endpoint.token_path, "rb") as source:
        token = source.read()
    module = runpy.run_path(notify, run_name="bridge_test")
    assert hello["signature"] == hmac.new(token, module["canonical"](hello), hashlib.sha256).hexdigest()
    assert endpoint.hello_publication_checks == [True] * expected_count

previous = Endpoint(fixture["previous_socket"])
replacement = None
parallel = None
replacement_process = None
enrollment_gate = None
try:
    setup(fixture["previous_setup"])
    assert previous.frames.get(timeout=2)["message"] == "enroll"
    require_published_hello(previous)
    hook()
    assert previous.frames.get(timeout=2)["message"] == "event"
    with open(token_path, "rb") as source:
        initial_token = source.read()
    with open(journal_path, "rt", encoding="utf-8") as source:
        initial_journal = json.load(source)

    if not fixture["keep_previous_alive"]:
        previous.close()
    assert stat.S_ISSOCK(os.stat(fixture["previous_socket"]).st_mode)
    assert fixture["previous_socket"] != fixture["replacement_socket"]
    if fixture.get("verify_parallel_route_progress", False):
        parallel = Endpoint(fixture["parallel_socket"], route_id=fixture["parallel_route_id"])
        setup(fixture["parallel_setup"])
        assert parallel.frames.get(timeout=2)["message"] == "enroll"
        require_published_hello(parallel)
    if fixture.get("verify_parallel_route_progress", False) or fixture.get("unregister_during_enrollment", False):
        enrollment_gate = threading.Event()
    replacement = Endpoint(
        fixture["replacement_socket"], fixture.get("drop_first_replacement_ack", False),
        fixture.get("enrollment_ack_delay_seconds", 0), enrollment_gate=enrollment_gate
    )
    if enrollment_gate is None:
        setup(fixture["replacement_setup"])
    else:
        replacement_process = subprocess.Popen(["/bin/sh", "-c", fixture["replacement_setup"]])
        assert replacement.first_enrollment_seen.wait(timeout=2)
        if fixture.get("unregister_during_enrollment", False):
            setup(fixture["replacement_cleanup"], timeout=2)
            assert not enrollment_gate.is_set()
            assert not os.path.exists(route_path) and not os.path.exists(token_path)
            enrollment_gate.set()
            assert replacement_process.wait(timeout=4) == 0
            assert replacement.frames.get(timeout=2)["message"] == "enroll"
            assert replacement.frames.empty() and not replacement.hello_publication_checks
            assert not any(os.path.exists(path) for path in (route_path, token_path, journal_path))
            print(json.dumps({"unregister_completed_before_ack": True,
                              "unregister_during_ack_did_not_resurrect": True,
                              "revoked_registration_did_not_send_hello": True}))
            raise SystemExit(0)
        hook(tmux_session=fixture["parallel_tmux_session"], timeout=2)
        assert parallel.frames.get(timeout=2)["message"] == "event"
        assert not enrollment_gate.is_set()
        setup(fixture["parallel_setup"], timeout=2)
        assert parallel.frames.get(timeout=2)["message"] == "enroll"
        require_published_hello(parallel, expected_count=2)
        assert not enrollment_gate.is_set()
        enrollment_gate.set()
        assert replacement_process.wait(timeout=4) == 0
    enrollment = replacement.frames.get(timeout=2)
    assert enrollment["message"] == "enroll"
    assert enrollment["route_id"] == fixture["route_id"]
    assert enrollment["connection_id"] == fixture["replacement_connection_id"]
    if fixture.get("drop_first_replacement_ack", False):
        assert replacement.frames.get(timeout=2) == enrollment
    require_published_hello(replacement)
    assert replacement.frames.empty()
    with open(route_path, "rt", encoding="utf-8") as source:
        route = json.load(source)
    assert route["socket_path"] == fixture["replacement_socket"]
    assert route["connection_id"] == fixture["replacement_connection_id"]
    module = runpy.run_path(notify, run_name="bridge_test")
    assert module["candidate_routes"](fixture["tmux_session"])[0][3] == fixture["replacement_socket"]

    if fixture["keep_previous_alive"]:
        # An old SSH setup that finishes after replacement is rejected by the
        # current Mac generation. Its late reply cannot retarget route.json.
        previous.response = {"accepted": False, "duplicate": False, "code": "superseded"}
        setup(fixture["previous_setup"])
        assert previous.frames.get(timeout=2)["message"] == "enroll"
        with open(route_path, "rt", encoding="utf-8") as source:
            assert json.load(source) == route
        assert previous.hello_publication_checks == [True]
        assert module["candidate_routes"](fixture["tmux_session"])[0][3] == fixture["replacement_socket"]
        # Losing an obsolete connection's reply is not authorization to replace
        # the accepted generation either. Drain any bounded retry frames.
        previous.response = None
        setup(fixture["previous_setup"])
        assert previous.frames.get(timeout=2)["message"] == "enroll"
        while not previous.frames.empty():
            assert previous.frames.get_nowait()["message"] == "enroll"
        with open(route_path, "rt", encoding="utf-8") as source:
            assert json.load(source) == route
        assert previous.hello_publication_checks == [True]

    hook()
    event = replacement.frames.get(timeout=2)
    assert event["message"] == "event" and event["event_type"] == "stop"
    assert event["route_id"] == fixture["route_id"]
    assert event["connection_id"] == fixture["replacement_connection_id"]
    assert event["session_id"] == session_id and event["tmux_pane"] == "%7"
    assert event["signature"] == hmac.new(initial_token, module["canonical"](event), hashlib.sha256).hexdigest()
    assert previous.frames.empty()
    with open(token_path, "rb") as source:
        assert source.read() == initial_token
    with open(journal_path, "rt", encoding="utf-8") as source:
        latest_journal = json.load(source)
    for key in ("route_id", "session_id", "session_kind", "cwd", "tmux_pane"):
        assert latest_journal[key] == initial_journal[key]

    if fixture["keep_previous_alive"]:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
            probe.settimeout(1)
            probe.connect(fixture["previous_socket"])
    if fixture.get("invalidate_settings_after_replacement", False):
        settings_path = os.path.join(home, ".claude", "settings.json")
        invalid_settings = b'{"hooks":{"Stop":"not-an-array"}}'
        with open(settings_path, "wb") as output:
            output.write(invalid_settings)
        setup(fixture["replacement_setup"])
        unready = replacement.frames.get(timeout=2)
        assert unready["message"] == "enroll" and unready["integration_ready"] is False
        assert replacement.frames.empty()
        assert replacement.hello_publication_checks == [True]
        with open(settings_path, "rb") as source:
            assert source.read() == invalid_settings
    print(json.dumps({
        "replacement_bound_first_time": True,
        "previous_socket_was_orphaned": not fixture["keep_previous_alive"],
        "previous_socket_still_live": fixture["keep_previous_alive"],
        "replacement_enrolled": True,
        "hook_reached_replacement": True,
        "stable_token_and_session": True,
        "no_hook_sent_to_previous_connection": True,
        "superseded_registration_kept_replacement": fixture["keep_previous_alive"],
        "offline_old_registration_kept_replacement": fixture["keep_previous_alive"],
        "lost_ack_retried_same_enrollment": fixture.get("drop_first_replacement_ack", False),
        "published_before_signed_hello": True,
        "rejected_registration_did_not_send_hello": fixture["keep_previous_alive"],
        "slow_enrollment_acknowledgement_received": fixture.get("enrollment_ack_delay_seconds", 0) > 0.75,
        "unready_registration_did_not_send_hello": fixture.get("invalidate_settings_after_replacement", False),
        "invalid_settings_left_untouched": fixture.get("invalidate_settings_after_replacement", False),
        "other_route_hook_completed_before_ack": fixture.get("verify_parallel_route_progress", False),
        "other_route_registration_completed_before_ack": fixture.get("verify_parallel_route_progress", False),
    }))
finally:
    if enrollment_gate is not None:
        enrollment_gate.set()
    if replacement_process is not None and replacement_process.poll() is None:
        try:
            replacement_process.wait(timeout=4)
        except subprocess.TimeoutExpired:
            replacement_process.terminate()
            replacement_process.wait(timeout=4)
    previous.close()
    if replacement is not None:
        replacement.close()
    if parallel is not None:
        parallel.close()
"""#

    private func runRemoteShell(_ command: String, home: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["PATH"] = environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func candidateEndpoint(
        notify: URL,
        home: URL,
        tmuxSession: String
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            """
            import os, runpy
            module = runpy.run_path(os.environ["NOTIFY_PATH"], run_name="bridge_test")
            candidates = module["candidate_routes"](os.environ["TMUX_SESSION"])
            endpoint = candidates[0][3] if candidates else None
            print(endpoint if isinstance(endpoint, (int, str)) else "invalid")
            """,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["NOTIFY_PATH"] = notify.path
        environment["TMUX_SESSION"] = tmuxSession
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        #expect(process.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
