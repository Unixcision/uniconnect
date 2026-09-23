import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// La bandeja de entrada del móvil (`inbox.v1`): listar, leer y borrar sin salir nunca de la carpeta.
/// Mismo contrato que `linux/tests/test_inbox.py`.
@Suite("Bandeja de entrada del móvil")
struct MobileInboxServiceTests {
    private static let ahora = Date(timeIntervalSince1970: 2_000_000_000)
    private static let dia: TimeInterval = 86_400

    private struct Bandeja {
        let base: URL
        let root: URL
        let service: MobileInboxService

        init() throws {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("uc-inbox-\(UUID().uuidString)", isDirectory: true)
            root = base.appendingPathComponent("Entrada", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            service = MobileInboxService(baseDirectory: root, now: { MobileInboxServiceTests.ahora })
        }

        @discardableResult
        func archivo(_ relativo: String, _ tamaño: Int, diasAtras: Double) throws -> URL {
            let url = root.appendingPathComponent(relativo)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x78, count: tamaño).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: MobileInboxServiceTests.ahora.addingTimeInterval(-diasAtras * MobileInboxServiceTests.dia)],
                ofItemAtPath: url.path
            )
            return url
        }

        func limpiar() { try? FileManager.default.removeItem(at: base) }
    }

    @Test("Lista lo nuevo primero, con tipo y total")
    func listaOrdenada() async throws {
        let b = try Bandeja(); defer { b.limpiar() }
        try b.archivo("20260901/viejo.pdf", 10, diasAtras: 20)
        try b.archivo("20260923/video.mp4", 300, diasAtras: 0)
        try b.archivo("20260922/foto.JPG", 50, diasAtras: 1)
        let r = await b.service.list()
        #expect(r.entries.map(\.name) == ["video.mp4", "foto.JPG", "viejo.pdf"])
        #expect(r.entries.map(\.kind) == [.video, .image, .document])
        #expect(r.count == 3 && r.totalBytes == 360)
        #expect(r.entries[0].absolute.hasSuffix("Entrada/20260923/video.mp4"))
    }

    @Test("No lista subidas a medias, ocultos ni enlaces")
    func sinPartesNiEnlaces() async throws {
        let b = try Bandeja(); defer { b.limpiar() }
        try b.archivo("20260923/bueno.txt", 5, diasAtras: 0)
        try b.archivo("20260923/subiendo.mp4.part", 999, diasAtras: 0)
        try b.archivo("20260923/.oculto", 7, diasAtras: 0)
        let fuera = b.base.appendingPathComponent("secreto.txt")
        try Data("no".utf8).write(to: fuera)
        try FileManager.default.createSymbolicLink(
            at: b.root.appendingPathComponent("20260923/enlace.txt"), withDestinationURL: fuera)
        #expect(await b.service.list().entries.map(\.name) == ["bueno.txt"])
    }

    @Test("No se sale de la carpeta", arguments: ["../fuera.txt", "/etc/passwd", "20260923/../../fuera.txt", ""])
    func noSeSale(_ mala: String) async throws {
        let b = try Bandeja(); defer { b.limpiar() }
        try b.archivo("20260923/a.txt", 1, diasAtras: 0)
        await #expect(throws: MobileInboxError.self) { try await b.service.read(path: mala, offset: 0, length: 10) }
    }

    @Test("Un enlace simbólico hacia fuera no se lee")
    func enlaceNoSeLee() async throws {
        let b = try Bandeja(); defer { b.limpiar() }
        try FileManager.default.createDirectory(at: b.root.appendingPathComponent("20260923"), withIntermediateDirectories: true)
        let fuera = b.base.appendingPathComponent("secreto.txt")
        try Data("no".utf8).write(to: fuera)
        try FileManager.default.createSymbolicLink(
            at: b.root.appendingPathComponent("20260923/trampa.txt"), withDestinationURL: fuera)
        await #expect(throws: MobileInboxError.self) {
            try await b.service.read(path: "20260923/trampa.txt", offset: 0, length: 10)
        }
    }

    @Test("Sin criterio no se borra nada")
    func sinCriterio() async throws {
        let b = try Bandeja(); defer { b.limpiar() }
        try b.archivo("20260923/a.txt", 1, diasAtras: 0)
        await #expect(throws: MobileInboxError.missingCriterion) { try await b.service.delete(MobileInboxDeletion()) }
        #expect(await b.service.list().count == 1)
    }

    @Test("Los criterios se suman")
    func criteriosSeSuman() async throws {
        let b = try Bandeja(); defer { b.limpiar() }
        try b.archivo("20260901/viejo_grande.mp4", 500, diasAtras: 30)
        try b.archivo("20260901/viejo_pequeño.txt", 5, diasAtras: 30)
        try b.archivo("20260923/nuevo_grande.mp4", 500, diasAtras: 0)
        var c = MobileInboxDeletion(); c.olderThanDays = 7; c.largerThanBytes = 100
        let r = try await b.service.delete(c)
        #expect(r.deleted == 1 && r.freedBytes == 500)
        #expect(await b.service.list().entries.map(\.name).sorted() == ["nuevo_grande.mp4", "viejo_pequeño.txt"])
    }

    @Test("La simulación dice lo mismo sin tocar nada")
    func simulacion() async throws {
        let b = try Bandeja(); defer { b.limpiar() }
        try b.archivo("20260901/a.mp4", 400, diasAtras: 30)
        try b.archivo("20260923/b.mp4", 100, diasAtras: 0)
        var c = MobileInboxDeletion(); c.olderThanDays = 7; c.dryRun = true
        let simulado = try await b.service.delete(c)
        #expect(simulado.deleted == 1 && simulado.freedBytes == 400 && simulado.remainingBytes == 100)
        #expect(await b.service.list().count == 2)
        c.dryRun = false
        let real = try await b.service.delete(c)
        #expect(real.deleted == 1 && real.freedBytes == 400 && real.remainingBytes == 100)
    }

    @Test("Borrar todo respeta las subidas en marcha y limpia carpetas vacías")
    func borrarTodo() async throws {
        let b = try Bandeja(); defer { b.limpiar() }
        try b.archivo("20260901/a.txt", 3, diasAtras: 30)
        try b.archivo("20260923/b.txt", 3, diasAtras: 0)
        let parte = try b.archivo("20260923/c.mp4.part", 9, diasAtras: 0)
        var c = MobileInboxDeletion(); c.everything = true
        #expect(try await b.service.delete(c).deleted == 2)
        #expect(FileManager.default.fileExists(atPath: parte.path), "una subida en marcha no se borra")
        #expect(!FileManager.default.fileExists(atPath: b.root.appendingPathComponent("20260901").path))
        #expect(FileManager.default.fileExists(atPath: b.root.path), "la raíz nunca se quita")
    }

    @Test("Leer por trozos reconstruye el archivo")
    func leerPorTrozos() async throws {
        let b = try Bandeja(); defer { b.limpiar() }
        let url = try b.archivo("20260923/a.bin", 0, diasAtras: 0)
        let contenido = Data((0..<2560).map { UInt8($0 % 256) })
        try contenido.write(to: url)
        let uno = try await b.service.read(path: "20260923/a.bin", offset: 0, length: 1000)
        let dos = try await b.service.read(path: "20260923/a.bin", offset: 1000, length: 5000)
        #expect(uno.data + dos.data == contenido)
        #expect(uno.size == 2560 && !uno.endOfFile && dos.endOfFile)
    }

    @Test("Tipos por extensión")
    func tipos() {
        #expect(["a.HEIC", "b.m4a", "c.webm", "d", "e.xyz"].map(MobileInboxKind.init(fileName:)) == [.image, .audio, .video, .other, .other])
    }
}
