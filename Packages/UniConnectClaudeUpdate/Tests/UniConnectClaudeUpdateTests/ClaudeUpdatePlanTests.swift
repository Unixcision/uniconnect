import Foundation
import Testing
@testable import UniConnectClaudeUpdate

@Suite("Claude update plan validation")
struct ClaudeUpdatePlanTests {
    @Test func groupsTargetsOncePerCredentialHostInDiscoveryOrder() throws {
        let fixture = ClaudeUpdateTestFixture()
        let remoteOne = fixture.target(id: "remote-1", host: fixture.remoteHost, paneID: "%1")
        let local = fixture.target(id: "local-1")
        let remoteTwo = fixture.target(id: "remote-2", host: fixture.remoteHost, paneID: "%2")

        let plan = try ClaudeUpdatePlan(
            scope: .allOpen,
            targets: [remoteOne, local, remoteTwo]
        )

        #expect(plan.hosts.count == 2)
        #expect(plan.hosts[0].host == fixture.remoteHost)
        #expect(plan.hosts[0].targets.map(\.id) == [remoteOne.id, remoteTwo.id])
        #expect(plan.hosts[1].host == fixture.localHost)
        #expect(plan.hosts[1].targets.map(\.id) == [local.id])
    }

    @Test func rejectsDuplicateVisibleTargetIdentifiers() throws {
        let fixture = ClaudeUpdateTestFixture()
        let first = fixture.target(id: "same")
        let second = fixture.target(id: "same")

        do {
            _ = try ClaudeUpdatePlan(scope: .allOpen, targets: [first, second])
            Issue.record("Expected duplicate target validation to fail")
        } catch let error as ClaudeUpdatePlanError {
            #expect(error == .duplicateTargetID(first.id))
        }
    }

    @Test func rejectsDuplicateClaudeSessionUUIDsAcrossTargets() throws {
        let fixture = ClaudeUpdateTestFixture()
        let sessionID = UUID()
        let first = fixture.target(id: "first", sessionID: sessionID)
        let second = fixture.target(id: "second", sessionID: sessionID)

        do {
            _ = try ClaudeUpdatePlan(scope: .allOpen, targets: [first, second])
            Issue.record("Expected duplicate UUID validation to fail")
        } catch let error as ClaudeUpdatePlanError {
            #expect(error == .duplicateSessionID(sessionID, first: first.id, second: second.id))
        }
    }

    @Test func rejectsDuplicateRemotePaneOwnership() throws {
        let fixture = ClaudeUpdateTestFixture()
        let first = fixture.target(id: "first", host: fixture.remoteHost, paneID: "%7")
        let second = fixture.target(id: "second", host: fixture.remoteHost, paneID: "%7")

        do {
            _ = try ClaudeUpdatePlan(scope: .allOpen, targets: [first, second])
            Issue.record("Expected duplicate pane validation to fail")
        } catch let error as ClaudeUpdatePlanError {
            guard case let .duplicatePane(hostID, pane, owner, duplicate) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(hostID == fixture.remoteHost.id)
            #expect(pane.paneID == "%7")
            #expect(owner == first.id)
            #expect(duplicate == second.id)
        }
    }

    @Test func rejectsMultipleInstallationsOnOneHost() throws {
        let fixture = ClaudeUpdateTestFixture()
        let native = fixture.target(id: "native")
        let npm = fixture.target(
            id: "npm",
            installationID: "npm:/usr/local/lib/node_modules/claude",
            executablePath: "/usr/local/bin/claude"
        )

        do {
            _ = try ClaudeUpdatePlan(scope: .allOpen, targets: [native, npm])
            Issue.record("Expected conflicting installation validation to fail")
        } catch let error as ClaudeUpdatePlanError {
            guard case let .conflictingInstallations(hostID, installationIDs) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(hostID == fixture.localHost.id)
            #expect(installationIDs.count == 2)
        }
    }
}
