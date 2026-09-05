import CryptoKit
import Foundation
import Testing
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class UniConnectVaultCredentialRecordTests: XCTestCase {
    func testDecoderRejectsInvalidCredentialIdentifierWithoutSilentlyDroppingIt() throws {
        let plaintext = try JSONEncoder().encode([
            "not-a-credential-uuid": "ssh invalid-id-alias",
        ])

        try assertVaultRejects(plaintext: plaintext, fixtureName: "invalid-id")
    }

    func testDecoderRejectsDistinctKeysThatCanonicalizeToTheSameUUID() throws {
        let credentialID = UUID(uuidString: "70000000-0000-0000-0000-00000000000A")!
        let uppercaseID = credentialID.uuidString
        let lowercaseID = uppercaseID.lowercased()
        XCTAssertNotEqual(uppercaseID, lowercaseID)
        let plaintext = try JSONEncoder().encode([
            uppercaseID: "ssh first-alias",
            lowercaseID: "ssh second-alias",
        ])

        try assertVaultRejects(plaintext: plaintext, fixtureName: "duplicate-id")
    }

    func testDecoderRejectsEmptyCommandsInLegacyAndVersionedPayloads() throws {
        let credentialID = UUID()
        let legacy = try JSONEncoder().encode([
            credentialID.uuidString: " \t\n ",
        ])
        try assertVaultRejects(plaintext: legacy, fixtureName: "empty-legacy-command")

        let versioned = try JSONSerialization.data(withJSONObject: [
            "format": "uniconnect-ssh-credential-vault",
            "version": 1,
            "entries": [
                credentialID.uuidString: [
                    "connectCommand": "  ",
                ],
            ],
        ])
        try assertVaultRejects(plaintext: versioned, fixtureName: "empty-record-command")
    }

    func testStoreAPIsRejectEmptyCommandsWithoutCreatingCiphertext() throws {
        let fixture = makeFixture(name: "empty-store-command")
        defer { fixture.remove() }
        let vault = fixture.makeVault()
        let target = try makeTarget(user: "deploy", host: "safe.internal.test", port: 22)

        XCTAssertThrowsError(try vault.storeOrThrow(connectCommand: " \t\n "))
        XCTAssertThrowsError(try vault.storeOrThrow(
            connectCommand: "  ",
            effectiveTarget: target
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.path))
        XCTAssertTrue(vault.allIds().isEmpty)
    }

    func testLegacyPayloadLoadsAndMigratesToEncryptedRecordStorageWithPrivatePermissions() throws {
        let fixture = makeFixture(name: "legacy")
        defer { fixture.remove() }
        let credentialID = UUID(uuidString: "71000000-0000-0000-0000-000000000001")!
        let command = "ssh legacy-production"
        let legacyPlaintext = try JSONEncoder().encode([
            credentialID.uuidString: command,
        ])
        try UniConnectAtomicFileWriter.write(
            try UniConnectCrypto.seal(legacyPlaintext, key: fixture.key),
            to: fixture.url
        )

        let vault = fixture.makeVault()
        XCTAssertEqual(vault.connectCommand(for: credentialID), command)
        XCTAssertNil(vault.effectiveTarget(for: credentialID))

        let target = try makeTarget(user: "release-user", host: "origin.internal.test", port: 2207)
        try vault.storeOrThrow(
            connectCommand: "  \(command)\n",
            effectiveTarget: target,
            id: credentialID
        )

        let reloaded = fixture.makeVault()
        XCTAssertEqual(
            reloaded.credentialRecord(for: credentialID),
            UniConnectSSHCredentialRecord(connectCommand: command, effectiveTarget: target)
        )
        XCTAssertEqual(reloaded.effectiveTarget(for: credentialID), target)

        let encrypted = try Data(contentsOf: fixture.url)
        let diskText = String(decoding: encrypted, as: UTF8.self)
        XCTAssertFalse(diskText.contains("legacy-production"))
        XCTAssertFalse(diskText.contains("release-user"))
        XCTAssertFalse(diskText.contains("origin.internal.test"))
        let plaintext = try UniConnectCrypto.open(
            UniConnectCrypto.parseEnvelope(encrypted),
            key: fixture.key
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: plaintext) as? [String: Any]
        )
        XCTAssertEqual(payload["format"] as? String, "uniconnect-ssh-credential-vault")
        XCTAssertEqual(payload["version"] as? Int, 1)
        XCTAssertNotNil((payload["entries"] as? [String: Any])?[credentialID.uuidString])

        let fileMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: fixture.url.path)[.posixPermissions]
                as? NSNumber
        ).intValue
        let directoryMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: fixture.directory.path)[.posixPermissions]
                as? NSNumber
        ).intValue
        XCTAssertEqual(fileMode & 0o777, 0o600)
        XCTAssertEqual(directoryMode & 0o777, 0o700)
    }

    func testLegacyStoreAPIDoesNotEraseAnExistingResolvedTargetOnNoOp() throws {
        let fixture = makeFixture(name: "legacy-api")
        defer { fixture.remove() }
        let credentialID = UUID()
        let command = "ssh stable-alias"
        let target = try makeTarget(user: "ops", host: "stable.internal.test", port: 22)
        let vault = fixture.makeVault()
        try vault.storeOrThrow(
            connectCommand: command,
            effectiveTarget: target,
            id: credentialID
        )
        let before = try XCTUnwrap(vault.encryptedSnapshot())

        try vault.storeOrThrow(connectCommand: " \(command) ", id: credentialID)

        XCTAssertTrue(vault.matchesExactEncryptedSnapshot(before))
        XCTAssertEqual(vault.effectiveTarget(for: credentialID), target)

        XCTAssertThrowsError(try vault.storeOrThrow(
            connectCommand: "ssh retargeted-alias",
            id: credentialID
        ))
        XCTAssertTrue(vault.matchesExactEncryptedSnapshot(before))
        XCTAssertEqual(
            vault.credentialRecord(for: credentialID),
            UniConnectSSHCredentialRecord(connectCommand: command, effectiveTarget: target)
        )
    }

    func testSnapshotsKeepCompleteRecordsWithoutMutatingTheLiveVault() throws {
        let fixture = makeFixture(name: "snapshot")
        defer { fixture.remove() }
        let credentialID = UUID()
        let supplementalID = UUID()
        let command = "ssh deployment-alias"
        let targetA = try makeTarget(user: "deploy", host: "blue.internal.test", port: 2222)
        let targetB = try makeTarget(user: "deploy", host: "green.internal.test", port: 2222)
        let vault = fixture.makeVault()
        try vault.storeOrThrow(
            connectCommand: command,
            effectiveTarget: targetA,
            id: credentialID
        )
        let snapshotA = try XCTUnwrap(vault.encryptedSnapshot(requiring: [credentialID]))

        try vault.storeOrThrow(
            connectCommand: command,
            effectiveTarget: targetB,
            id: credentialID
        )
        let captured = try vault.credentialRecords(
            fromEncryptedSnapshot: snapshotA,
            requiring: [credentialID]
        )
        XCTAssertEqual(captured[credentialID]?.effectiveTarget, targetA)
        XCTAssertEqual(vault.effectiveTarget(for: credentialID), targetB)
        XCTAssertEqual(
            try vault.connectCommands(
                fromEncryptedSnapshot: snapshotA,
                requiring: [credentialID]
            )[credentialID],
            command
        )
        let exactRestore = UniConnectVault(
            storageURL: fixture.directory.appendingPathComponent("exact-restore.uc"),
            keyProvider: { fixture.key }
        )
        try exactRestore.restoreExactEncryptedSnapshot(snapshotA)
        XCTAssertEqual(exactRestore.effectiveTarget(for: credentialID), targetA)

        let supplemental = UniConnectSSHCredentialRecord(
            connectCommand: "ssh audit-alias",
            effectiveTarget: targetA
        )
        let combined = try XCTUnwrap(vault.encryptedSnapshot(including: [
            supplementalID: supplemental,
        ]))
        XCTAssertNil(vault.credentialRecord(for: supplementalID))
        XCTAssertEqual(
            try vault.credentialRecords(
                fromEncryptedSnapshot: combined,
                requiring: [supplementalID]
            )[supplementalID],
            supplemental
        )
        XCTAssertThrowsError(try vault.encryptedSnapshot(including: [
            credentialID: UniConnectSSHCredentialRecord(
                connectCommand: command,
                effectiveTarget: targetA
            ),
        ]))
    }

    func testImmutableRevisionIdentityIncludesTheEffectiveTarget() throws {
        let fixture = makeFixture(name: "revision")
        defer { fixture.remove() }
        let sourceID = UUID(uuidString: "72000000-0000-0000-0000-000000000001")!
        let command = "ssh moving-alias"
        let targetA = try makeTarget(user: "ops", host: "first.internal.test", port: 22)
        let targetB = try makeTarget(user: "ops", host: "second.internal.test", port: 22)
        let vault = fixture.makeVault()
        try vault.storeOrThrow(
            connectCommand: command,
            effectiveTarget: targetA,
            id: sourceID
        )
        let revisionA = try vault.immutableRevision(for: sourceID)

        try vault.storeOrThrow(
            connectCommand: command,
            effectiveTarget: targetB,
            id: sourceID
        )
        let revisionB = try vault.immutableRevision(for: sourceID)

        XCTAssertNotEqual(revisionA, revisionB)
        XCTAssertEqual(vault.effectiveTarget(for: revisionA), targetA)
        XCTAssertEqual(vault.effectiveTarget(for: revisionB), targetB)
        XCTAssertEqual(try vault.immutableRevision(for: sourceID), revisionB)

        let explicitRevisionID = UUID()
        XCTAssertEqual(
            try vault.createImmutableRevision(
                connectCommand: "ssh explicit-revision",
                effectiveTarget: targetA,
                id: explicitRevisionID
            ),
            explicitRevisionID
        )
        XCTAssertEqual(vault.effectiveTarget(for: explicitRevisionID), targetA)
    }

    func testCommandOnlyRecordsKeepTheirLegacyDeterministicRevisionIDs() throws {
        let fixture = makeFixture(name: "legacy-revision")
        defer { fixture.remove() }
        let sourceID = UUID(uuidString: "74000000-0000-0000-0000-000000000001")!
        let command = "ssh legacy-revision"
        let vault = fixture.makeVault()
        try vault.storeOrThrow(connectCommand: command, id: sourceID)

        XCTAssertEqual(
            try vault.immutableRevision(for: sourceID),
            UUID(uuidString: "BEB8B963-47B2-B71B-E862-4AA24A495B4F")
        )

        let current = UniConnectVault(
            storageURL: fixture.directory.appendingPathComponent("legacy-current.uc"),
            keyProvider: { fixture.key }
        )
        let backup = UniConnectVault(
            storageURL: fixture.directory.appendingPathComponent("legacy-backup.uc"),
            keyProvider: { fixture.key }
        )
        try current.storeOrThrow(connectCommand: "ssh current-revision", id: sourceID)
        try backup.storeOrThrow(connectCommand: command, id: sourceID)
        let backupSnapshot = try XCTUnwrap(backup.encryptedSnapshot())
        let mapping = try current.mergeEncryptedBackup(backupSnapshot)
        XCTAssertEqual(
            mapping[sourceID],
            UUID(uuidString: "35D92C0D-6F67-7C46-68A0-EBCCB9CF56F4")
        )
    }

    func testMergeRemapsSameAliasWhenItsEffectiveEndpointChanged() throws {
        let fixture = makeFixture(name: "merge")
        defer { fixture.remove() }
        let currentURL = fixture.directory.appendingPathComponent("current.uc")
        let backupURL = fixture.directory.appendingPathComponent("backup.uc")
        let credentialID = UUID(uuidString: "73000000-0000-0000-0000-000000000001")!
        let command = "ssh production"
        let targetA = try makeTarget(user: "deploy", host: "old.internal.test", port: 22)
        let targetB = try makeTarget(user: "deploy", host: "new.internal.test", port: 22)
        let current = UniConnectVault(storageURL: currentURL, keyProvider: { fixture.key })
        let backup = UniConnectVault(storageURL: backupURL, keyProvider: { fixture.key })
        try current.storeOrThrow(
            connectCommand: command,
            effectiveTarget: targetA,
            id: credentialID
        )
        try backup.storeOrThrow(
            connectCommand: command,
            effectiveTarget: targetB,
            id: credentialID
        )
        let backupSnapshot = try XCTUnwrap(backup.encryptedSnapshot())

        let firstMap = try current.mergeEncryptedBackup(backupSnapshot)
        let recoveredID = try XCTUnwrap(firstMap[credentialID])

        XCTAssertNotEqual(recoveredID, credentialID)
        XCTAssertEqual(current.effectiveTarget(for: credentialID), targetA)
        XCTAssertEqual(current.effectiveTarget(for: recoveredID), targetB)
        XCTAssertNil(current.credentialID(matching: command, excluding: nil))
        XCTAssertEqual(
            current.credentialID(
                matching: UniConnectSSHCredentialRecord(
                    connectCommand: command,
                    effectiveTarget: targetB
                ),
                excluding: nil
            ),
            recoveredID
        )
        XCTAssertEqual(try current.mergeEncryptedBackup(backupSnapshot), firstMap)
        XCTAssertEqual(current.allIds().count, 2)
    }

    func testImportRollbackComparesTheCompleteRecordAndPreservesConcurrentEdits() throws {
        let fixture = makeFixture(name: "rollback")
        defer { fixture.remove() }
        let credentialID = UUID()
        let command = "ssh rollout"
        let targetA = try makeTarget(user: "deploy", host: "a.internal.test", port: 22)
        let targetB = try makeTarget(user: "deploy", host: "b.internal.test", port: 22)
        let targetC = try makeTarget(user: "deploy", host: "c.internal.test", port: 22)
        let vault = fixture.makeVault()
        try vault.storeOrThrow(
            connectCommand: command,
            effectiveTarget: targetA,
            id: credentialID
        )
        let checkpoint = try XCTUnwrap(vault.encryptedSnapshot())
        try vault.storeOrThrow(
            connectCommand: command,
            effectiveTarget: targetB,
            id: credentialID
        )
        let expected = try XCTUnwrap(vault.encryptedSnapshot())

        _ = try vault.restoreImportDelta(checkpoint: checkpoint, expected: expected)
        XCTAssertEqual(vault.effectiveTarget(for: credentialID), targetA)

        let secondCheckpoint = try XCTUnwrap(vault.encryptedSnapshot())
        try vault.storeOrThrow(
            connectCommand: command,
            effectiveTarget: targetB,
            id: credentialID
        )
        let secondExpected = try XCTUnwrap(vault.encryptedSnapshot())
        try vault.storeOrThrow(
            connectCommand: command,
            effectiveTarget: targetC,
            id: credentialID
        )

        let restored = try XCTUnwrap(vault.restoreImportDelta(
            checkpoint: secondCheckpoint,
            expected: secondExpected
        ))
        XCTAssertEqual(vault.effectiveTarget(for: credentialID), targetC)
        XCTAssertEqual(
            try vault.credentialRecords(
                fromEncryptedSnapshot: restored,
                requiring: [credentialID]
            )[credentialID]?.effectiveTarget,
            targetC
        )
    }

    private func makeTarget(
        user: String,
        host: String,
        port: Int
    ) throws -> UniConnectSSHEffectiveTarget {
        try XCTUnwrap(UniConnectSSHEffectiveTarget(user: user, host: host, port: port))
    }

    private func assertVaultRejects(
        plaintext: Data,
        fixtureName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let fixture = makeFixture(name: fixtureName)
        defer { fixture.remove() }
        let encrypted = try UniConnectCrypto.seal(plaintext, key: fixture.key)
        try UniConnectAtomicFileWriter.write(encrypted, to: fixture.url)
        let vault = fixture.makeVault()

        XCTAssertThrowsError(
            try vault.storeOrThrow(connectCommand: "ssh replacement-alias"),
            file: file,
            line: line
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.url),
            encrypted,
            file: file,
            line: line
        )
    }

    private func makeFixture(name: String) -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "uniconnect-vault-record-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        return Fixture(
            directory: directory,
            url: directory.appendingPathComponent("vault.uc"),
            key: SymmetricKey(data: Data(repeating: 0x71, count: 32))
        )
    }

    private struct Fixture {
        let directory: URL
        let url: URL
        let key: SymmetricKey

        func makeVault() -> UniConnectVault {
            UniConnectVault(storageURL: url, keyProvider: { self.key })
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

@Suite("UniConnect legacy credential startup hydration")
struct UniConnectLegacyCredentialHydrationTests {
    @Test("Legacy UUIDs and commands survive migration with an exact encrypted backup")
    func preservesLegacyIdentityAndBackup() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let credentialID = UUID()
        let command = "ssh deploy@legacy.internal.test"
        let original = try UniConnectCrypto.seal(
            JSONEncoder().encode([credentialID.uuidString: command]),
            key: fixture.key
        )
        try UniConnectAtomicFileWriter.write(original, to: fixture.url)
        let vault = fixture.makeVault()
        let target = try #require(UniConnectSSHEffectiveTarget(
            user: "deploy", host: "legacy.internal.test", port: 22
        ))

        let migrated = try vault.hydrateLegacyEffectiveTargets { requests in
            #expect(requests.count == 1)
            #expect(requests.first?.originalHost == "legacy.internal.test")
            return [.resolved(target)]
        }

        #expect(migrated == 1)
        #expect(vault.allIds() == [credentialID])
        #expect(vault.connectCommand(for: credentialID) == command)
        #expect(fixture.makeVault().effectiveTarget(for: credentialID) == target)
        let backups = try FileManager.default.contentsOfDirectory(
            at: fixture.directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("vault-before-target-migration-") }
        #expect(backups.count == 1)
        let backup = try #require(backups.first)
        #expect(try Data(contentsOf: backup) == original)
        let migratedBytes = try Data(contentsOf: fixture.url)
        #expect(!String(decoding: migratedBytes, as: UTF8.self).contains("legacy.internal.test"))

        let repeated = try vault.hydrateLegacyEffectiveTargets { _ in
            Issue.record("Resolved endpoints must never be re-resolved on later launches")
            return []
        }
        #expect(repeated == 0)
        #expect(try Data(contentsOf: fixture.url) == migratedBytes)
    }

    @Test("Unresolved and already-pinned records remain untouched")
    func preservesUnresolvedAndPinnedRecords() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let vault = fixture.makeVault()
        let legacyID = UUID()
        let pinnedID = UUID()
        let pinnedTarget = try #require(UniConnectSSHEffectiveTarget(
            user: "ops", host: "pinned.internal.test", port: 2201
        ))
        try vault.storeOrThrow(connectCommand: "ssh unresolved-alias", id: legacyID)
        try vault.storeOrThrow(
            connectCommand: "ssh pinned-alias",
            effectiveTarget: pinnedTarget,
            id: pinnedID
        )
        let original = try Data(contentsOf: fixture.url)

        let migrated = try vault.hydrateLegacyEffectiveTargets { requests in
            #expect(requests.map(\.originalHost) == ["unresolved-alias"])
            return [.indeterminate]
        }

        #expect(migrated == 0)
        #expect(try Data(contentsOf: fixture.url) == original)
        #expect(vault.effectiveTarget(for: legacyID) == nil)
        #expect(vault.effectiveTarget(for: pinnedID) == pinnedTarget)
        #expect(Set(vault.allIds()) == Set([legacyID, pinnedID]))
    }

    @Test("Concurrent edits win over stale startup resolution")
    func refusesConcurrentCredentialEdits() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let vault = fixture.makeVault()
        let credentialID = UUID()
        let firstTarget = try #require(UniConnectSSHEffectiveTarget(
            user: "ops", host: "first.internal.test", port: 22
        ))
        let editedTarget = try #require(UniConnectSSHEffectiveTarget(
            user: "ops", host: "edited.internal.test", port: 22
        ))
        try vault.storeOrThrow(connectCommand: "ssh first-alias", id: credentialID)

        #expect(throws: (any Error).self) {
            try vault.hydrateLegacyEffectiveTargets { _ in
                do {
                    try vault.storeOrThrow(
                        connectCommand: "ssh edited-alias",
                        effectiveTarget: editedTarget,
                        id: credentialID
                    )
                } catch {
                    Issue.record("Fixture concurrent edit could not be persisted")
                }
                return [.resolved(firstTarget)]
            }
        }

        #expect(vault.connectCommand(for: credentialID) == "ssh edited-alias")
        #expect(vault.effectiveTarget(for: credentialID) == editedTarget)
        #expect(fixture.makeVault().effectiveTarget(for: credentialID) == editedTarget)
    }

    @Test("A truncated resolver batch cannot partially update the vault")
    func rejectsUnexpectedResolverBatchSize() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let vault = fixture.makeVault()
        let credentialID = UUID()
        try vault.storeOrThrow(connectCommand: "ssh fixture-alias", id: credentialID)
        let original = try Data(contentsOf: fixture.url)

        let migrated = try vault.hydrateLegacyEffectiveTargets { _ in [] }

        #expect(migrated == 0)
        #expect(vault.effectiveTarget(for: credentialID) == nil)
        #expect(try Data(contentsOf: fixture.url) == original)
    }

    private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "uniconnect-legacy-hydration-\(UUID().uuidString)", isDirectory: true
        )
        let key = SymmetricKey(data: Data(repeating: 0x72, count: 32))
        var url: URL { directory.appendingPathComponent("vault.uc") }

        func makeVault() -> UniConnectVault {
            UniConnectVault(storageURL: url, keyProvider: { self.key })
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
