import CryptoKit
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// Salto SSH falso: registra la llamada y devuelve lo que el test decida.
private final class FakeRemoteCopier: MobileFileRemoteCopying, @unchecked Sendable {
    // Solo lo escribe el test antes de usarlo y lo lee el actor después; sin concurrencia real.
    var result: MobileFileRemoteCopyResult = .copied(remotePath: "/home/deploy/uniconnect-entrada/foto.jpg")
    var calls: [(URL, String)] = []

    func copy(localURL: URL, name: MobileFilePutName, credentialRecord: UniConnectSSHCredentialRecord, timeout: TimeInterval) async -> MobileFileRemoteCopyResult {
        calls.append((localURL, name.fileName))
        return result
    }
}

/// Nombre saneado, script remoto y flujo completo begin → chunk → commit del servicio.
@Suite("file_put.v1 en el host Mac")
struct MobileFilePutServiceTests {
    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeBaseDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UniConnectFilePut-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func localBinding(peer: String? = "100.125.34.113") -> MobileFilePutBinding {
        MobileFilePutBinding(peerAddress: peer, workspaceID: UUID(), credentialID: nil, credentialRecord: nil)
    }

    private func sshBinding() throws -> MobileFilePutBinding {
        let target = try #require(UniConnectSSHEffectiveTarget(user: "deploy", host: "server.example", port: 22))
        let record = UniConnectSSHCredentialRecord(connectCommand: "ssh deploy@server.example", effectiveTarget: target)
        return MobileFilePutBinding(peerAddress: "100.125.34.113", workspaceID: UUID(), credentialID: UUID(), credentialRecord: record)
    }

    @Test("El nombre se sanea: sin rutas, sin caracteres peligrosos, extensión conservada, longitud acotada")
    func nameSanitizing() {
        #expect(MobileFilePutName(rawName: "../../etc/passwd").fileName == "passwd")
        #expect(MobileFilePutName(rawName: "C:\\Users\\dani\\foto de ayer.JPG").fileName == "foto_de_ayer.JPG")
        #expect(MobileFilePutName(rawName: "  .oculto.txt ").fileName == "oculto.txt")
        #expect(MobileFilePutName(rawName: "a;b|c$(rm)`x`'y'.png").fileName == "a_b_c_(rm)_x__y_.png")
        #expect(MobileFilePutName(rawName: "foto (1).jpg").fileName == "foto_(1).jpg")
        #expect(MobileFilePutName(rawName: "").fileName == "archivo")
        #expect(MobileFilePutName(rawName: "...").fileName == "archivo")
        #expect(MobileFilePutName(rawName: "informe.tar.gz").ext == ".gz")
        #expect(MobileFilePutName(rawName: "sin extension").ext == "")
        let long = MobileFilePutName(rawName: String(repeating: "á", count: 200) + ".jpeg")
        #expect(long.fileName.utf8.count <= MobileFilePutName.maximumUTF8Bytes)
        #expect(long.ext == ".jpeg")
        let name = MobileFilePutName(rawName: "foto.jpg")
        #expect(name.candidate(1) == "foto.jpg")
        #expect(name.candidate(2) == "foto-2.jpg")
        #expect(name.candidate(3) == "foto-3.jpg")
    }

    @Test("El script remoto escribe en temporal, mueve sin sobrescribir y prueba -2, -3…")
    func remoteScript() {
        let script = MobileFileSSHCopier.remoteScript(name: MobileFilePutName(rawName: "foto.jpg"), nonce: "abc123")
        #expect(script.contains("mkdir -p \"$d\""))
        #expect(script.contains("t=\"$d/\"'.foto.jpg.abc123.part'"))
        #expect(script.contains("cat > \"$t\""))
        #expect(script.contains("n=\"$d/\"'foto.jpg'"))
        #expect(script.contains("mv -n \"$t\" \"$n\""))
        #expect(script.contains("[ -e \"$t\" ] || break"))
        #expect(script.contains("n=\"$d/\"'foto'\"-$i\"'.jpg'"))
        #expect(script.contains("printf '%s\\n' \"$n\""))
        #expect(script.hasPrefix("set -e"))
        #expect(!script.contains("rm "))
    }

    @Test("Flujo local: begin reserva el .part, los trozos se suman y commit verifica el sha")
    func localFlow() async throws {
        let base = try makeBaseDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let copier = FakeRemoteCopier()
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let service = MobileFilePutService(baseDirectory: base, remoteCopier: copier, now: { day })
        let binding = localBinding()
        let content = Data((0..<3000).map { UInt8($0 % 251) })
        let begin = try await service.begin(name: "nota.txt", size: content.count, mime: "text/plain", terminalID: nil, binding: binding)
        #expect(begin.chunkBytes == 1_048_576)
        let dayFolder = base.appendingPathComponent(MobileFilePutService.dayFolder(for: day))
        #expect(FileManager.default.fileExists(atPath: dayFolder.appendingPathComponent("nota.txt.part").path))

        let first = content.prefix(1000)
        let second = content.dropFirst(1000)
        #expect(try await service.appendChunk(transferID: begin.transferID, index: 0, base64: first.base64EncodedString(), binding: binding) == 1000)
        await #expect(throws: MobileFilePutError.self) {
            try await service.appendChunk(transferID: begin.transferID, index: 0, base64: first.base64EncodedString(), binding: binding)
        }
        #expect(try await service.appendChunk(transferID: begin.transferID, index: 1, base64: second.base64EncodedString(), binding: binding) == 3000)

        let commit = try await service.commit(transferID: begin.transferID, sha256: sha256Hex(content).uppercased(), binding: binding)
        #expect(commit.location == .host)
        #expect(commit.remotePath == nil)
        #expect(commit.path == dayFolder.appendingPathComponent("nota.txt").path)
        #expect(try Data(contentsOf: URL(fileURLWithPath: commit.path)) == content)
        #expect(!FileManager.default.fileExists(atPath: dayFolder.appendingPathComponent("nota.txt.part").path))
        #expect(copier.calls.isEmpty)
        #expect(await service.activeTransferIDs.isEmpty)
    }

    @Test("Dos subidas concurrentes del mismo nombre reciben nombres distintos y nada se sobrescribe")
    func concurrentReservations() async throws {
        let base = try makeBaseDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let service = MobileFilePutService(baseDirectory: base, remoteCopier: FakeRemoteCopier())
        let binding = localBinding()
        let a = try await service.begin(name: "foto.jpg", size: 1, mime: nil, terminalID: nil, binding: binding)
        let b = try await service.begin(name: "foto.jpg", size: 1, mime: nil, terminalID: nil, binding: binding)
        _ = try await service.appendChunk(transferID: a.transferID, index: 0, base64: Data([1]).base64EncodedString(), binding: binding)
        _ = try await service.appendChunk(transferID: b.transferID, index: 0, base64: Data([2]).base64EncodedString(), binding: binding)
        let commitB = try await service.commit(transferID: b.transferID, sha256: sha256Hex(Data([2])), binding: binding)
        let commitA = try await service.commit(transferID: a.transferID, sha256: sha256Hex(Data([1])), binding: binding)
        #expect(commitA.path.hasSuffix("/foto.jpg"))
        #expect(commitB.path.hasSuffix("/foto-2.jpg"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: commitA.path)) == Data([1]))
        #expect(try Data(contentsOf: URL(fileURLWithPath: commitB.path)) == Data([2]))
        let c = try await service.begin(name: "foto.jpg", size: 0, mime: nil, terminalID: nil, binding: binding)
        let commitC = try await service.commit(transferID: c.transferID, sha256: sha256Hex(Data()), binding: binding)
        #expect(commitC.path.hasSuffix("/foto-3.jpg"))
    }

    @Test("sha o tamaño incorrectos descartan el .part; tamaño anunciado superado es too_large")
    func integrityFailures() async throws {
        let base = try makeBaseDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let service = MobileFilePutService(baseDirectory: base, remoteCopier: FakeRemoteCopier())
        let binding = localBinding()
        let content = Data("hola".utf8)

        let short = try await service.begin(name: "a.txt", size: 10, mime: nil, terminalID: nil, binding: binding)
        _ = try await service.appendChunk(transferID: short.transferID, index: 0, base64: content.base64EncodedString(), binding: binding)
        await #expect(throws: MobileFilePutError.self) {
            try await service.commit(transferID: short.transferID, sha256: sha256Hex(content), binding: binding)
        }
        #expect(await service.activeTransferIDs.isEmpty)

        let wrongSha = try await service.begin(name: "b.txt", size: 4, mime: nil, terminalID: nil, binding: binding)
        _ = try await service.appendChunk(transferID: wrongSha.transferID, index: 0, base64: content.base64EncodedString(), binding: binding)
        await #expect(throws: MobileFilePutError.self) {
            try await service.commit(transferID: wrongSha.transferID, sha256: String(repeating: "0", count: 64), binding: binding)
        }

        let overflow = try await service.begin(name: "c.txt", size: 2, mime: nil, terminalID: nil, binding: binding)
        do {
            _ = try await service.appendChunk(transferID: overflow.transferID, index: 0, base64: content.base64EncodedString(), binding: binding)
            Issue.record("Se esperaba too_large")
        } catch let error as MobileFilePutError {
            #expect(error == .tooLarge)
        }
        await #expect(throws: MobileFilePutError.self) {
            _ = try await service.begin(name: "d.bin", size: MobileFilePutService.maximumSize + 1, mime: nil, terminalID: nil, binding: binding)
        }
        let parts = try FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent(MobileFilePutService.dayFolder(for: Date())).path)
        #expect(parts.filter { $0.hasSuffix(".part") }.isEmpty)
    }

    @Test("Otra ligadura (dispositivo, caja o credencial) es not_found; abort borra el .part")
    func bindingAndAbort() async throws {
        let base = try makeBaseDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let service = MobileFilePutService(baseDirectory: base, remoteCopier: FakeRemoteCopier())
        let binding = try sshBinding()
        let begin = try await service.begin(name: "x.bin", size: 1, mime: nil, terminalID: nil, binding: binding)
        #expect(await service.binding(of: begin.transferID) == binding)
        let otherDevice = MobileFilePutBinding(peerAddress: "100.1.1.1", workspaceID: binding.workspaceID, credentialID: binding.credentialID, credentialRecord: binding.credentialRecord)
        let editedTarget = try #require(UniConnectSSHEffectiveTarget(user: "root", host: "server.example", port: 22))
        let editedCredential = MobileFilePutBinding(
            peerAddress: binding.peerAddress, workspaceID: binding.workspaceID, credentialID: binding.credentialID,
            credentialRecord: UniConnectSSHCredentialRecord(connectCommand: "ssh root@server.example", effectiveTarget: editedTarget)
        )
        for wrong in [otherDevice, editedCredential] {
            do {
                _ = try await service.appendChunk(transferID: begin.transferID, index: 0, base64: Data([9]).base64EncodedString(), binding: wrong)
                Issue.record("Se esperaba not_found")
            } catch let error as MobileFilePutError {
                #expect(error == .notFound)
            }
        }
        #expect(await service.binding(of: UUID()) == nil)
        try await service.abort(transferID: begin.transferID, binding: binding)
        #expect(await service.activeTransferIDs.isEmpty)
        let parts = try FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent(MobileFilePutService.dayFolder(for: Date())).path)
        #expect(parts.isEmpty)
    }

    @Test("Caja SSH: el commit salta al servidor y devuelve remote_path, o el path del host con remote_error")
    func sshHop() async throws {
        let base = try makeBaseDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let copier = FakeRemoteCopier()
        let service = MobileFilePutService(baseDirectory: base, remoteCopier: copier)
        let binding = try sshBinding()
        let content = Data("imagen".utf8)

        let ok = try await service.begin(name: "foto.jpg", size: content.count, mime: "image/jpeg", terminalID: nil, binding: binding)
        _ = try await service.appendChunk(transferID: ok.transferID, index: 0, base64: content.base64EncodedString(), binding: binding)
        let copied = try await service.commit(transferID: ok.transferID, sha256: sha256Hex(content), binding: binding)
        #expect(copied.location == .remote)
        #expect(copied.remotePath == "/home/deploy/uniconnect-entrada/foto.jpg")
        #expect(copied.remoteError == nil)
        #expect(copied.path.hasSuffix("/foto.jpg"))
        #expect(copier.calls.count == 1)
        #expect(copier.calls.first?.1 == "foto.jpg")

        copier.result = .failed("ssh exit 255")
        let failing = try await service.begin(name: "foto.jpg", size: content.count, mime: nil, terminalID: nil, binding: binding)
        _ = try await service.appendChunk(transferID: failing.transferID, index: 0, base64: content.base64EncodedString(), binding: binding)
        let kept = try await service.commit(transferID: failing.transferID, sha256: sha256Hex(content), binding: binding)
        #expect(kept.location == .host)
        #expect(kept.remotePath == nil)
        #expect(kept.remoteError == "ssh exit 255")
        #expect(kept.path.hasSuffix("/foto-2.jpg"))
        #expect(FileManager.default.fileExists(atPath: kept.path))
    }

    @Test("Una transferencia sin trozos caduca y su .part desaparece")
    func expiry() async throws {
        let base = try makeBaseDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let service = MobileFilePutService(baseDirectory: base, remoteCopier: FakeRemoteCopier(), expiry: .milliseconds(20))
        let binding = localBinding()
        let begin = try await service.begin(name: "lento.bin", size: 5, mime: nil, terminalID: nil, binding: binding)
        // Espera de prueba bien por encima de la caducidad inyectada.
        try await Task.sleep(for: .milliseconds(300))
        #expect(await service.binding(of: begin.transferID) == nil)
        do {
            _ = try await service.appendChunk(transferID: begin.transferID, index: 0, base64: Data([1]).base64EncodedString(), binding: binding)
            Issue.record("Se esperaba not_found tras caducar")
        } catch let error as MobileFilePutError {
            #expect(error == .notFound)
        }
        let parts = try FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent(MobileFilePutService.dayFolder(for: Date())).path)
        #expect(parts.isEmpty)
    }
}
