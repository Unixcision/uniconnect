import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// Construye un WAV PCM en memoria para medir duraciones sin tocar el disco ni `ffmpeg`.
private struct WAVFixture {
    let sampleRate: Int
    let channels: Int
    let bitsPerSample: Int
    let seconds: Double

    init(sampleRate: Int = 16_000, channels: Int = 1, bitsPerSample: Int = 16, seconds: Double) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
        self.seconds = seconds
    }

    var data: Data {
        let bytesPerFrame = channels * bitsPerSample / 8
        let dataBytes = Int(seconds * Double(sampleRate)) * bytesPerFrame
        var out = Data()
        out.append(contentsOf: Array("RIFF".utf8))
        out.append(Self.uint32(UInt32(36 + dataBytes)))
        out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8))
        out.append(Self.uint32(16))
        out.append(Self.uint16(1))
        out.append(Self.uint16(UInt16(channels)))
        out.append(Self.uint32(UInt32(sampleRate)))
        out.append(Self.uint32(UInt32(sampleRate * bytesPerFrame)))
        out.append(Self.uint16(UInt16(bytesPerFrame)))
        out.append(Self.uint16(UInt16(bitsPerSample)))
        out.append(contentsOf: Array("data".utf8))
        out.append(Self.uint32(UInt32(dataBytes)))
        out.append(Data(repeating: 0, count: dataBytes))
        return out
    }

    private static func uint16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    private static func uint32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ])
    }
}

/// Lanzador falso: apunta las órdenes que se construyen y devuelve resultados preparados.
private actor RecordingRunner: MobileTranscriptionProcessRunning {
    struct Invocation: Equatable {
        let executable: URL
        let arguments: [String]
    }

    private var queued: [MobileTranscriptionProcessResult]
    private var recorded: [Invocation] = []
    private let holdForever: Bool

    init(results: [MobileTranscriptionProcessResult] = [], holdForever: Bool = false) {
        self.queued = results
        self.holdForever = holdForever
    }

    var invocations: [Invocation] { recorded }

    func run(executable: URL, arguments: [String]) async throws -> MobileTranscriptionProcessResult {
        recorded.append(Invocation(executable: executable, arguments: arguments))
        if holdForever {
            try await Task.sleep(for: .seconds(10))
        }
        guard !queued.isEmpty else {
            return MobileTranscriptionProcessResult(exitStatus: 0, standardOutput: Data(), standardError: Data())
        }
        return queued.removeFirst()
    }

    static func succeeding(text: String) -> MobileTranscriptionProcessResult {
        MobileTranscriptionProcessResult(
            exitStatus: 0,
            standardOutput: Data(text.utf8),
            standardError: Data()
        )
    }
}

@Suite("transcribe.v1: validación de la petición")
struct MobileTranscriptionLimitsTests {
    private let limits = MobileTranscriptionLimits()

    @Test("el presupuesto es de 75 s con 5 s reservados para limpiar")
    func budget() {
        #expect(limits.budget == .seconds(75))
        #expect(limits.workingBudget == .seconds(70))
    }

    @Test("un base64 mal formado se rechaza con invalid_params, no en silencio")
    func malformedBase64() {
        var capturado: MobileTranscriptionError?
        do {
            _ = try limits.validate(base64: "no es base64 ###", mime: "audio/wav", language: nil, device: nil)
        } catch let error as MobileTranscriptionError {
            capturado = error
        } catch {
            Issue.record("fallo inesperado: \(error)")
        }
        #expect(capturado?.code == "invalid_params")
    }

    @Test("una cadena con basura dentro no se cuela decodificada a medias")
    func garbageInsideBase64() throws {
        let limpio = Data("hola qué tal".utf8).base64EncodedString()
        var sucio = limpio
        sucio.insert("*", at: sucio.index(sucio.startIndex, offsetBy: 3))
        var capturado: MobileTranscriptionError?
        do {
            _ = try limits.validate(base64: sucio, mime: "audio/wav", language: nil, device: nil)
        } catch let error as MobileTranscriptionError {
            capturado = error
        }
        #expect(capturado?.code == "invalid_params")
    }

    @Test("los saltos de línea del base64 sí se toleran")
    func base64WithNewlines() throws {
        let audio = Data(repeating: 7, count: 300)
        var encoded = audio.base64EncodedString()
        encoded.insert("\n", at: encoded.index(encoded.startIndex, offsetBy: 8))
        let request = try limits.validate(base64: encoded, mime: "audio/wav", language: nil, device: nil)
        #expect(request.audio == audio)
    }

    @Test("un clip por encima del tamaño es too_large antes de decodificar")
    func tooLargeByBytes() {
        let enorme = String(repeating: "A", count: limits.maximumBase64Characters + 8)
        var capturado: MobileTranscriptionError?
        do {
            _ = try limits.validate(base64: enorme, mime: "audio/wav", language: nil, device: nil)
        } catch let error as MobileTranscriptionError {
            capturado = error
        }
        #expect(capturado == .tooLarge)
    }

    @Test("la duración medida manda sobre el MIME", arguments: [301.0, 600.0])
    func tooLargeByDuration(seconds: Double) {
        #expect(throws: MobileTranscriptionError.tooLarge) {
            try limits.verify(seconds: seconds)
        }
    }

    @Test("una duración dentro del tope pasa")
    func durationWithinLimit() throws {
        try limits.verify(seconds: 299.5)
    }

    @Test("solo se aceptan los formatos del contrato")
    func mimeParsing() {
        #expect(MobileTranscriptionAudioFormat.parse("audio/mp4") == .mp4)
        #expect(MobileTranscriptionAudioFormat.parse("AUDIO/MP4; codecs=mp4a.40.2") == .mp4)
        #expect(MobileTranscriptionAudioFormat.parse("audio/x-m4a") == .mp4)
        #expect(MobileTranscriptionAudioFormat.parse("audio/ogg") == .ogg)
        #expect(MobileTranscriptionAudioFormat.parse("audio/wav") == .wav)
        #expect(MobileTranscriptionAudioFormat.parse("audio/flac") == nil)
        #expect(MobileTranscriptionAudioFormat.parse(nil) == nil)
    }

    @Test("el idioma se normaliza o se rechaza")
    func languageNormalisation() throws {
        let audio = Data(repeating: 1, count: 64).base64EncodedString()
        #expect(try limits.validate(base64: audio, mime: "audio/wav", language: "es-ES", device: nil).language == "es")
        #expect(try limits.validate(base64: audio, mime: "audio/wav", language: "EN", device: nil).language == "en")
        #expect(try limits.validate(base64: audio, mime: "audio/wav", language: "  ", device: nil).language == nil)
        #expect(try limits.validate(base64: audio, mime: "audio/wav", language: nil, device: nil).language == nil)
        var capturado: MobileTranscriptionError?
        do {
            _ = try limits.validate(base64: audio, mime: "audio/wav", language: "fr", device: nil)
        } catch let error as MobileTranscriptionError {
            capturado = error
        }
        #expect(capturado?.code == "invalid_params")
    }
}

@Suite("transcribe.v1: códigos de error del contrato")
struct MobileTranscriptionErrorTests {
    @Test("cada fallo lleva el código que espera el móvil")
    func codes() {
        #expect(MobileTranscriptionError.invalidParams("x").code == "invalid_params")
        #expect(MobileTranscriptionError.tooLarge.code == "too_large")
        #expect(MobileTranscriptionError.unsupported("x").code == "unsupported")
        #expect(MobileTranscriptionError.busy.code == "busy")
        #expect(MobileTranscriptionError.ioFailed("x").code == "io_failed")
    }

    @Test("ningún mensaje del contrato viaja vacío")
    func messages() {
        #expect(!MobileTranscriptionError.tooLarge.message.isEmpty)
        #expect(!MobileTranscriptionError.busy.message.isEmpty)
        #expect(MobileTranscriptionError.unsupported("falta el modelo").message == "falta el modelo")
    }
}

@Suite("transcribe.v1: aforo")
struct MobileTranscriptionAdmissionTests {
    @Test("un dispositivo no puede tener dos dictados a la vez")
    func perDevice() {
        var admission = MobileTranscriptionAdmission(perDevice: 1, total: 2)
        #expect(admission.admit(device: "100.1.1.1"))
        #expect(!admission.admit(device: "100.1.1.1"))
        admission.release(device: "100.1.1.1")
        #expect(admission.admit(device: "100.1.1.1"))
    }

    @Test("el equipo no pasa de dos dictados en total")
    func hostWide() {
        var admission = MobileTranscriptionAdmission(perDevice: 1, total: 2)
        #expect(admission.admit(device: "a"))
        #expect(admission.admit(device: "b"))
        #expect(!admission.admit(device: "c"))
        #expect(admission.activeCount == 2)
        admission.release(device: "a")
        #expect(admission.admit(device: "c"))
    }

    @Test("una llamada sin dispositivo tampoco se salta el aforo")
    func anonymousDevice() {
        var admission = MobileTranscriptionAdmission(perDevice: 1, total: 2)
        #expect(admission.admit(device: nil))
        #expect(!admission.admit(device: "   "))
    }
}

@Suite("transcribe.v1: elección de modelo")
struct MobileWhisperModelCatalogTests {
    @Test("se prefiere el modelo rápido y la elección no depende del sistema de archivos")
    func preference() {
        let nombres = ["ggml-large-v3.bin", "ggml-large-v3-turbo-q5_0.bin", "ggml-base.bin"]
        #expect(MobileWhisperModelCatalog.choose(from: nombres) == "ggml-large-v3-turbo-q5_0.bin")
        #expect(MobileWhisperModelCatalog.choose(from: nombres.reversed()) == "ggml-large-v3-turbo-q5_0.bin")
    }

    @Test("large sin cuantizar queda por detrás de los pequeños")
    func largeIsLast() {
        #expect(MobileWhisperModelCatalog.choose(from: ["ggml-large-v3.bin", "ggml-small.bin"]) == "ggml-small.bin")
    }

    @Test("una carpeta sin modelos no elige nada")
    func emptyDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = MobileWhisperModelCatalog(directory: directory)
        #expect(catalog.preferredModel() == nil)
        try Data("x".utf8).write(to: directory.appendingPathComponent("ggml-base.bin"))
        #expect(MobileWhisperModelCatalog(directory: directory).preferredModel()?.lastPathComponent == "ggml-base.bin")
    }
}

@Suite("transcribe.v1: construcción de las órdenes")
struct MobileTranscriptionCommandTests {
    @Test("whisper-cli recibe modelo, audio, idioma e hilos, sin marcas de tiempo")
    func whisperArguments() {
        let command = MobileWhisperCLICommand(
            model: URL(fileURLWithPath: "/modelos/ggml-base.bin"),
            audio: URL(fileURLWithPath: "/tmp/clip.wav"),
            language: "es",
            threads: 6
        )
        #expect(command.arguments == [
            "-m", "/modelos/ggml-base.bin",
            "-f", "/tmp/clip.wav",
            "-l", "es",
            "-t", "6",
            "-nt",
            "-np",
        ])
    }

    @Test("sin idioma se pide detección automática")
    func automaticLanguage() {
        let command = MobileWhisperCLICommand(
            model: URL(fileURLWithPath: "/m.bin"),
            audio: URL(fileURLWithPath: "/a.wav"),
            language: nil,
            threads: 1
        )
        #expect(command.arguments.contains("auto"))
    }

    @Test("los hilos dejan un núcleo libre y no pasan del tope", arguments: [(1, 1), (4, 3), (12, 8)])
    func threads(cores: Int, expected: Int) {
        #expect(MobileWhisperCLICommand.threadCount(cores: cores) == expected)
    }

    @Test("la conversión sale acotada en duración y en tamaño")
    func conversionCeilings() {
        let command = MobileAudioConversionCommand(
            input: URL(fileURLWithPath: "/tmp/clip.m4a"),
            output: URL(fileURLWithPath: "/tmp/clip-16k.wav"),
            maximumSeconds: 300
        )
        #expect(command.ceilingSeconds == 310)
        #expect(command.ceilingBytes == 310 * 32_000 + 1_024)
        let arguments = command.arguments
        #expect(arguments.contains("-nostdin"))
        #expect(arguments.contains("pcm_s16le"))
        #expect(arguments.contains("16000"))
        #expect(arguments.contains("-fs"))
        #expect(arguments.contains(String(command.ceilingBytes)))
    }

    @Test("ffprobe se lee tolerando lo que no es un número")
    func probeParsing() {
        #expect(MobileAudioProbeCommand.seconds(from: "12.480000\n") == 12.48)
        #expect(MobileAudioProbeCommand.seconds(from: "N/A\n") == nil)
        #expect(MobileAudioProbeCommand.seconds(from: "") == nil)
        let command = MobileAudioProbeCommand(input: URL(fileURLWithPath: "/tmp/clip.m4a"))
        #expect(command.arguments.last == "/tmp/clip.m4a")
    }
}

@Suite("transcribe.v1: cabecera WAV")
struct MobileWAVFormatTests {
    @Test("la duración sale del propio bloque de datos")
    func duration() throws {
        let header = try #require(MobileWAVFormat.parse(WAVFixture(seconds: 12).data))
        #expect(header.sampleRate == 16_000)
        #expect(header.channels == 1)
        #expect(abs(header.seconds - 12) < 0.001)
        #expect(header.isWhisperReady)
    }

    @Test("un WAV que no está en la forma de whisper se detecta")
    func notWhisperReady() throws {
        let fixture = WAVFixture(sampleRate: 44_100, channels: 2, seconds: 2)
        let header = try #require(MobileWAVFormat.parse(fixture.data))
        #expect(!header.isWhisperReady)
        #expect(abs(header.seconds - 2) < 0.01)
    }

    @Test("lo que no es un WAV no se interpreta como tal")
    func notAWAV() {
        #expect(MobileWAVFormat.parse(Data(repeating: 0, count: 128)) == nil)
        #expect(MobileWAVFormat.parse(Data()) == nil)
    }
}

@Suite("transcribe.v1: filtro de marcadores")
struct MobileWhisperTranscriptTests {
    @Test("los marcadores de whisper se van", arguments: [
        "[BLANK_AUDIO]", "[Music]", "[Applause]", "[Silence]", "[_TT_320]", "[ blank_audio ]",
    ])
    func markersAreDropped(marker: String) {
        #expect(MobileWhisperTranscript(raw: marker).text.isEmpty)
        #expect(MobileWhisperTranscript(raw: "Hola \(marker) qué tal").text == "Hola qué tal")
    }

    @Test("una línea legítima entre corchetes se conserva", arguments: [
        "[pendiente]", "[por confirmar]", "[nota para Dani]", "[2026-09-10]",
    ])
    func bracketedTextSurvives(line: String) {
        #expect(MobileWhisperTranscript(raw: line).text == line)
    }

    @Test("el dictado queda en una sola línea sin espacios sobrantes")
    func singleLine() {
        let crudo = "  Hola, buenas.\n[BLANK_AUDIO]\n  Esto es una prueba.  \n"
        #expect(MobileWhisperTranscript(raw: crudo).text == "Hola, buenas. Esto es una prueba.")
    }

    @Test("un corchete sin cerrar es texto, no un marcador a medias")
    func unclosedBracket() {
        #expect(MobileWhisperTranscript(raw: "abre [ y no cierra").text == "abre [ y no cierra")
    }

    @Test("una salida vacía da un texto vacío, no un fallo")
    func emptyOutput() {
        #expect(MobileWhisperTranscript(raw: "\n\n").text.isEmpty)
    }
}

@Suite("transcribe.v1: carpeta privada de trabajo")
struct MobileTranscriptionWorkspaceTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("uc-transcribe-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("el clip se escribe a 0600 y el directorio se borra entero")
    func writeAndRemove() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = MobileTranscriptionWorkspace(root: root)
        let directory = try workspace.makeCallDirectory()
        let clip = directory.appendingPathComponent("clip.wav")
        try workspace.write(Data(repeating: 3, count: 32), to: clip)
        let permissions = try #require(
            try FileManager.default.attributesOfItem(atPath: clip.path)[.posixPermissions] as? NSNumber
        )
        #expect(permissions.int16Value == 0o600)
        #expect(workspace.remove(directory))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("no se pisa un archivo que ya existe")
    func refusesToOverwrite() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = MobileTranscriptionWorkspace(root: root)
        let directory = try workspace.makeCallDirectory()
        let clip = directory.appendingPathComponent("clip.wav")
        try workspace.write(Data([1]), to: clip)
        #expect(throws: MobileTranscriptionError.self) {
            try workspace.write(Data([2]), to: clip)
        }
    }

    @Test("un borrado que el disco rechaza se responde como fallo, no como éxito")
    func removeReportsFailure() throws {
        let root = try makeRoot()
        let workspace = MobileTranscriptionWorkspace(root: root)
        let directory = try workspace.makeCallDirectory()
        defer {
            _ = directory.path.withCString { chflags($0, 0) }
            try? FileManager.default.removeItem(at: root)
        }
        try workspace.write(Data([1, 2, 3]), to: directory.appendingPathComponent("clip.wav"))
        _ = directory.path.withCString { chflags($0, UInt32(UF_IMMUTABLE)) }
        #expect(!workspace.remove(directory))
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("el dueño se lee del nombre del directorio")
    func ownerParsing() {
        #expect(MobileTranscriptionWorkspace.owner(ofDirectoryNamed: "4321-abcdef") == 4321)
        #expect(MobileTranscriptionWorkspace.owner(ofDirectoryNamed: "sin-pid") == nil)
        #expect(MobileTranscriptionWorkspace.owner(ofDirectoryNamed: "4321-") == nil)
        #expect(MobileTranscriptionWorkspace.owner(ofDirectoryNamed: "-abcdef") == nil)
    }

    @Test("el barrido borra lo abandonado y respeta lo vivo y lo ajeno")
    func sweep() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default
        let abandonado = root.appendingPathComponent("999999-muerto", isDirectory: true)
        let vivo = root.appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier)-vivo", isDirectory: true)
        let ajeno = root.appendingPathComponent("descargas", isDirectory: true)
        for directory in [abandonado, vivo, ajeno] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        MobileTranscriptionWorkspace(root: root).sweepOrphans()
        #expect(!manager.fileExists(atPath: abandonado.path))
        #expect(manager.fileExists(atPath: vivo.path))
        #expect(manager.fileExists(atPath: ajeno.path))
    }
}

@Suite("transcribe.v1: anuncio de la capacidad")
struct MobileTranscriptionAvailabilityTests {
    @Test("la respuesta se guarda mientras no caduque y luego se vuelve a mirar")
    func caching() {
        let counter = ProbeCounter()
        var availability = MobileTranscriptionAvailability(lifetime: .seconds(60)) {
            counter.increment()
            return true
        }
        let start = ContinuousClock.now
        #expect(availability.isAvailable(now: start))
        #expect(availability.isAvailable(now: start.advanced(by: .seconds(30))))
        #expect(counter.value == 1)
        #expect(availability.isAvailable(now: start.advanced(by: .seconds(61))))
        #expect(counter.value == 2)
    }

    @Test("sin motor ni modelo no se anuncia nada")
    func unavailable() {
        var availability = MobileTranscriptionAvailability(lifetime: .seconds(60)) { false }
        #expect(!availability.isAvailable(now: ContinuousClock.now))
    }
}

/// Contador compartido por el cierre de la comprobación y el test.
private final class ProbeCounter: @unchecked Sendable {
    // El test es de un solo hilo: el cierre se llama en la misma tarea que lee el valor.
    private var count = 0
    var value: Int { count }
    func increment() { count += 1 }
}

/// Apunta los directorios que el trabajo no pudo borrar.
private final class LeftoverRecorder: @unchecked Sendable {
    // El aviso llega desde la misma tarea que luego lee la cuenta; sin concurrencia real.
    private var directories: [URL] = []
    var count: Int { directories.count }
    func record(_ directory: URL) { directories.append(directory) }
}

/// Lanzador que, además de responder, deja el directorio de la llamada imposible de borrar.
///
/// Marca inmutable el directorio que contiene el audio que le pasan, que es la forma de que el
/// borrado del trabajo falle de verdad en mitad de la llamada, cuando el clip ya está escrito.
private actor SabotagingRunner: MobileTranscriptionProcessRunning {
    private let text: String

    init(text: String) {
        self.text = text
    }

    func run(executable: URL, arguments: [String]) async throws -> MobileTranscriptionProcessResult {
        if let index = arguments.firstIndex(of: "-f"), index + 1 < arguments.count {
            let directory = URL(fileURLWithPath: arguments[index + 1]).deletingLastPathComponent()
            _ = directory.path.withCString { chflags($0, UInt32(UF_IMMUTABLE)) }
        }
        return MobileTranscriptionProcessResult(
            exitStatus: 0,
            standardOutput: Data(text.utf8),
            standardError: Data()
        )
    }
}

@Suite("transcribe.v1: el trabajo de principio a fin")
struct MobileTranscriptionJobTests {
    private func makeWorkspace() throws -> (MobileTranscriptionWorkspace, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("uc-transcribe-job-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (MobileTranscriptionWorkspace(root: root), root)
    }

    private let whisper = URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli")
    private let model = URL(fileURLWithPath: "/modelos/ggml-base.bin")

    private func makeJob(
        workspace: MobileTranscriptionWorkspace,
        runner: any MobileTranscriptionProcessRunning,
        toolchain: MobileTranscriptionToolchain,
        limits: MobileTranscriptionLimits
    ) -> MobileTranscriptionJob {
        MobileTranscriptionJob(
            limits: limits,
            workspace: workspace,
            toolchain: toolchain,
            model: model,
            runner: runner,
            clock: ContinuousClock(),
            threads: 4
        )
    }

    @Test("un WAV ya en la forma de whisper no pasa por el conversor")
    func whisperReadyWAVSkipsConversion() async throws {
        let (workspace, root) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = RecordingRunner(results: [RecordingRunner.succeeding(text: " Hola qué tal.\n")])
        let job = makeJob(
            workspace: workspace,
            runner: runner,
            toolchain: MobileTranscriptionToolchain(whisperCLI: whisper, ffmpeg: nil, ffprobe: nil),
            limits: MobileTranscriptionLimits()
        )
        let request = MobileTranscriptionRequest(
            audio: WAVFixture(seconds: 3).data,
            format: .wav,
            language: "es",
            device: "100.1.1.1"
        )
        let outcome = try await job.run(request: request, remaining: .seconds(30))
        #expect(outcome.text == "Hola qué tal.")
        #expect(outcome.engine == "whisper.cpp/ggml-base.bin")
        #expect(abs(outcome.seconds - 3) < 0.01)
        let invocations = await runner.invocations
        #expect(invocations.count == 1)
        #expect(invocations[0].executable == whisper)
        #expect(invocations[0].arguments.contains("-nt"))
        #expect(FileManager.default.fileExists(atPath: root.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("si el borrado falla, el dictado se responde igual y el directorio queda apuntado")
    func reportsCleanupFailure() async throws {
        let (workspace, root) = try makeWorkspace()
        defer {
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
                _ = root.appendingPathComponent(entry).path.withCString { chflags($0, 0) }
            }
            try? FileManager.default.removeItem(at: root)
        }
        let reported = LeftoverRecorder()
        let job = MobileTranscriptionJob(
            limits: MobileTranscriptionLimits(),
            workspace: workspace,
            toolchain: MobileTranscriptionToolchain(whisperCLI: whisper, ffmpeg: nil, ffprobe: nil),
            model: model,
            runner: SabotagingRunner(text: "hola"),
            clock: ContinuousClock(),
            threads: 2,
            onCleanupFailure: { reported.record($0) }
        )
        let request = MobileTranscriptionRequest(
            audio: WAVFixture(seconds: 1).data,
            format: .wav,
            language: nil,
            device: nil
        )
        let outcome = try await job.run(request: request, remaining: .seconds(30))
        // El texto llega igual: perder la limpieza no es motivo para tirar un dictado.
        #expect(outcome.text == "hola")
        // Y el directorio que se quedó en el disco queda anotado para reintentarlo.
        #expect(reported.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
    }

    @Test("un clip comprimido sin conversor responde unsupported")
    func missingConverter() async throws {
        let (workspace, root) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let job = makeJob(
            workspace: workspace,
            runner: RecordingRunner(),
            toolchain: MobileTranscriptionToolchain(whisperCLI: whisper, ffmpeg: nil, ffprobe: nil),
            limits: MobileTranscriptionLimits()
        )
        let request = MobileTranscriptionRequest(
            audio: Data(repeating: 9, count: 512),
            format: .mp4,
            language: nil,
            device: nil
        )
        var capturado: MobileTranscriptionError?
        do {
            _ = try await job.run(request: request, remaining: .seconds(30))
        } catch let error as MobileTranscriptionError {
            capturado = error
        }
        #expect(capturado?.code == "unsupported")
    }

    @Test("un motor que falla se traduce en io_failed y no deja nada en el disco")
    func engineFailure() async throws {
        let (workspace, root) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = RecordingRunner(results: [
            MobileTranscriptionProcessResult(exitStatus: 1, standardOutput: Data(), standardError: Data("boom".utf8)),
        ])
        let job = makeJob(
            workspace: workspace,
            runner: runner,
            toolchain: MobileTranscriptionToolchain(whisperCLI: whisper, ffmpeg: nil, ffprobe: nil),
            limits: MobileTranscriptionLimits()
        )
        let request = MobileTranscriptionRequest(
            audio: WAVFixture(seconds: 1).data,
            format: .wav,
            language: nil,
            device: nil
        )
        var capturado: MobileTranscriptionError?
        do {
            _ = try await job.run(request: request, remaining: .seconds(30))
        } catch let error as MobileTranscriptionError {
            capturado = error
        }
        #expect(capturado?.code == "io_failed")
        // El mensaje que ve el móvil no lleva la salida de error del motor.
        #expect(capturado?.message.contains("boom") == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("un clip demasiado largo es too_large sin arrancar el motor")
    func tooLongClip() async throws {
        let (workspace, root) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = RecordingRunner()
        let job = makeJob(
            workspace: workspace,
            runner: runner,
            toolchain: MobileTranscriptionToolchain(whisperCLI: whisper, ffmpeg: nil, ffprobe: nil),
            limits: MobileTranscriptionLimits(maximumSeconds: 1)
        )
        let request = MobileTranscriptionRequest(
            audio: WAVFixture(seconds: 4).data,
            format: .wav,
            language: nil,
            device: nil
        )
        var capturado: MobileTranscriptionError?
        do {
            _ = try await job.run(request: request, remaining: .seconds(30))
        } catch let error as MobileTranscriptionError {
            capturado = error
        }
        #expect(capturado == .tooLarge)
        #expect(await runner.invocations.isEmpty)
    }

    @Test("el presupuesto agotado responde io_failed en vez de esperar al motor")
    func exhaustedBudget() async throws {
        let (workspace, root) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let job = makeJob(
            workspace: workspace,
            runner: RecordingRunner(),
            toolchain: MobileTranscriptionToolchain(whisperCLI: whisper, ffmpeg: nil, ffprobe: nil),
            limits: MobileTranscriptionLimits()
        )
        let request = MobileTranscriptionRequest(
            audio: WAVFixture(seconds: 1).data,
            format: .wav,
            language: nil,
            device: nil
        )
        var capturado: MobileTranscriptionError?
        do {
            _ = try await job.run(request: request, remaining: .zero)
        } catch let error as MobileTranscriptionError {
            capturado = error
        }
        #expect(capturado?.code == "io_failed")
    }

    @Test("un motor que no vuelve se corta al vencer el plazo y limpia el disco")
    func deadlineCutsTheEngine() async throws {
        let (workspace, root) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let job = makeJob(
            workspace: workspace,
            runner: RecordingRunner(holdForever: true),
            toolchain: MobileTranscriptionToolchain(whisperCLI: whisper, ffmpeg: nil, ffprobe: nil),
            limits: MobileTranscriptionLimits()
        )
        let request = MobileTranscriptionRequest(
            audio: WAVFixture(seconds: 1).data,
            format: .wav,
            language: nil,
            device: nil
        )
        var capturado: MobileTranscriptionError?
        do {
            _ = try await job.run(request: request, remaining: .milliseconds(80))
        } catch let error as MobileTranscriptionError {
            capturado = error
        }
        #expect(capturado?.code == "io_failed")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}

@Suite("transcribe.v1: el hijo y su grupo de procesos")
struct MobileTranscriptionProcessRunnerTests {
    @Test("lo que devuelve waitpid se traduce a código de salida o a señal en negativo")
    func exitStatusMapping() {
        #expect(MobileTranscriptionProcessRunner.exitStatus(raw: 0) == 0)
        #expect(MobileTranscriptionProcessRunner.exitStatus(raw: 1 << 8) == 1)
        #expect(MobileTranscriptionProcessRunner.exitStatus(raw: 3 << 8) == 3)
        #expect(MobileTranscriptionProcessRunner.exitStatus(raw: SIGKILL) == -SIGKILL)
        #expect(MobileTranscriptionProcessRunner.exitStatus(raw: SIGTERM) == -SIGTERM)
    }

    @Test("el hijo arranca en su propio grupo, que es lo que permite señalar al grupo entero")
    func childLeadsItsOwnGroup() throws {
        let spawner = MobileTranscriptionSpawner()
        let child = try spawner.spawn(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "ps -o pgid= -p $$"]
        )
        let output = FileHandle(fileDescriptor: child.standardOutputDescriptor, closeOnDealloc: true)
        let text = String(decoding: (try? output.readToEnd()) ?? Data(), as: UTF8.self)
        try? output.close()
        let errors = FileHandle(fileDescriptor: child.standardErrorDescriptor, closeOnDealloc: true)
        _ = try? errors.readToEnd()
        try? errors.close()
        var raw: Int32 = 0
        while waitpid(child.identifier, &raw, 0) < 0 && errno == EINTR {}
        let group = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(group == child.identifier)
    }

    @Test("un hijo normal devuelve su salida y su código")
    func capturesOutput() async throws {
        let runner = MobileTranscriptionProcessRunner()
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf hola; printf ay >&2; exit 3"]
        )
        #expect(result.standardOutputText == "hola")
        #expect(String(decoding: result.standardError, as: UTF8.self) == "ay")
        #expect(result.exitStatus == 3)
        #expect(!result.didSucceed)
    }

    @Test("un hijo que ignora TERM se mata igual, sin esperar a que termine solo")
    func killsAChildThatIgnoresTerm() async throws {
        let runner = MobileTranscriptionProcessRunner(escalation: .milliseconds(200))
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("uc-term-\(UUID().uuidString)", isDirectory: false)
        let started = ContinuousClock.now
        let task = Task {
            try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; echo listo > \(marker.path); sleep 45"]
            )
        }
        // No se cancela hasta que el hijo confirma que ya ignora TERM.
        while !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        defer { try? FileManager.default.removeItem(at: marker) }
        task.cancel()
        var capturado: (any Error)?
        do {
            _ = try await task.value
        } catch {
            capturado = error
        }
        #expect(capturado is CancellationError)
        // Si solo hubiera llegado el TERM que el hijo ignora, esto tardaría los 45 s del sleep.
        #expect(ContinuousClock.now - started < .seconds(15))
    }

    @Test("cancelar antes de arrancar no deja el hijo suelto ni cuelga la llamada")
    func cancellationBeforeStart() async throws {
        let runner = MobileTranscriptionProcessRunner(escalation: .milliseconds(200))
        let task = Task {
            // La tarea nace cancelada, así que la cancelación llega antes del arranque.
            try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 45"]
            )
        }
        task.cancel()
        var capturado: (any Error)?
        do {
            _ = try await task.value
        } catch {
            capturado = error
        }
        #expect(capturado is CancellationError)
    }

    @Test("ejecutar un hijo no cierra descriptores que son de otro")
    func doesNotCloseForeignDescriptors() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("uc-fd-\(UUID().uuidString)", isDirectory: false)
        try Data("ajeno".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let foreign = open(file.path, O_RDONLY)
        #expect(foreign >= 0)
        defer { close(foreign) }

        let runner = MobileTranscriptionProcessRunner()
        for _ in 0..<8 {
            _ = try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf x"]
            )
        }
        // Un cierre doble habría soltado este número para que lo reutilizara otro; si sigue
        // siendo nuestro y legible, nadie lo cerró por detrás.
        #expect(fcntl(foreign, F_GETFD) != -1)
        var buffer = [UInt8](repeating: 0, count: 8)
        let count = buffer.withUnsafeMutableBytes { read(foreign, $0.baseAddress, $0.count) }
        #expect(count == 5)
    }

    @Test("cancelar mata al hijo en vez de esperar a que termine")
    func cancellationKillsTheChild() async throws {
        let runner = MobileTranscriptionProcessRunner(escalation: .milliseconds(200))
        let started = ContinuousClock.now
        let task = Task {
            try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 30"]
            )
        }
        // El hijo tiene que existir antes de cancelar, o se cancelaría antes de arrancar.
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        var capturado: (any Error)?
        do {
            _ = try await task.value
        } catch {
            capturado = error
        }
        #expect(capturado is CancellationError)
        #expect(ContinuousClock.now - started < .seconds(10))
    }
}

@Suite("transcribe.v1: el servicio")
struct MobileTranscriptionServiceTests {
    private func makeService(
        toolchain: MobileTranscriptionToolchain,
        model: URL?,
        runner: any MobileTranscriptionProcessRunning = RecordingRunner(),
        limits: MobileTranscriptionLimits = MobileTranscriptionLimits()
    ) throws -> MobileTranscriptionService {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("uc-transcribe-svc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return MobileTranscriptionService(
            limits: limits,
            workspace: MobileTranscriptionWorkspace(root: root),
            resolveToolchain: { toolchain },
            resolveModel: { model },
            runner: runner,
            clock: ContinuousClock(),
            threads: 2
        )
    }

    @Test("sin motor no hay transcripción y el móvil se entera")
    func withoutEngine() async throws {
        let service = try makeService(
            toolchain: MobileTranscriptionToolchain(whisperCLI: nil, ffmpeg: nil, ffprobe: nil),
            model: URL(fileURLWithPath: "/m.bin")
        )
        var capturado: MobileTranscriptionError?
        do {
            _ = try await service.transcribe(
                base64: Data([1, 2, 3, 4]).base64EncodedString(),
                mime: "audio/wav",
                language: nil,
                device: nil,
                connectionID: nil,
                startedAt: ContinuousClock.now
            )
        } catch let error as MobileTranscriptionError {
            capturado = error
        }
        #expect(capturado?.code == "unsupported")
    }

    @Test("sin modelo tampoco, y el motivo lo dice")
    func withoutModel() async throws {
        let service = try makeService(
            toolchain: MobileTranscriptionToolchain(
                whisperCLI: URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli"),
                ffmpeg: nil,
                ffprobe: nil
            ),
            model: nil
        )
        var capturado: MobileTranscriptionError?
        do {
            _ = try await service.transcribe(
                base64: Data([1, 2, 3, 4]).base64EncodedString(),
                mime: "audio/wav",
                language: nil,
                device: nil,
                connectionID: nil,
                startedAt: ContinuousClock.now
            )
        } catch let error as MobileTranscriptionError {
            capturado = error
        }
        #expect(capturado?.code == "unsupported")
        #expect(capturado?.message.isEmpty == false)
    }

    @Test("un base64 mal formado se rechaza antes de tocar el motor")
    func rejectsMalformedBase64() async throws {
        let runner = RecordingRunner()
        let service = try makeService(
            toolchain: MobileTranscriptionToolchain(
                whisperCLI: URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli"),
                ffmpeg: nil,
                ffprobe: nil
            ),
            model: URL(fileURLWithPath: "/m.bin"),
            runner: runner
        )
        var capturado: MobileTranscriptionError?
        do {
            _ = try await service.transcribe(
                base64: "###",
                mime: "audio/wav",
                language: nil,
                device: nil,
                connectionID: nil,
                startedAt: ContinuousClock.now
            )
        } catch let error as MobileTranscriptionError {
            capturado = error
        }
        #expect(capturado?.code == "invalid_params")
        #expect(await runner.invocations.isEmpty)
    }

    @Test("una conexión que se cerró antes de registrar el trabajo no deja el dictado huérfano")
    func cancellationBeforeRegistration() async throws {
        let service = try makeService(
            toolchain: MobileTranscriptionToolchain(
                whisperCLI: URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli"),
                ffmpeg: nil,
                ffprobe: nil
            ),
            model: URL(fileURLWithPath: "/m.bin"),
            runner: RecordingRunner(holdForever: true)
        )
        let connectionID = UUID()
        // El aviso llega antes de que exista trabajo alguno que cancelar.
        await service.cancel(connectionID: connectionID)
        var capturado: MobileTranscriptionError?
        do {
            _ = try await service.transcribe(
                base64: WAVFixture(seconds: 1).data.base64EncodedString(),
                mime: "audio/wav",
                language: nil,
                device: "100.9.9.9",
                connectionID: connectionID,
                startedAt: ContinuousClock.now
            )
        } catch let error as MobileTranscriptionError {
            capturado = error
        }
        #expect(capturado?.code == "io_failed")
        #expect(await service.activeJobCount == 0)
    }

    @Test("un borrado que el disco rechaza queda apuntado en vez de darse por hecho")
    func recordsLeftovers() async throws {
        let service = try makeService(
            toolchain: MobileTranscriptionToolchain(whisperCLI: nil, ffmpeg: nil, ffprobe: nil),
            model: nil
        )
        #expect(await service.pendingCleanupCount == 0)
        await service.recordLeftover(URL(fileURLWithPath: "/tmp/uc-transcribe-fantasma"))
        #expect(await service.pendingCleanupCount == 1)
        // Apuntar dos veces el mismo directorio no lo duplica.
        await service.recordLeftover(URL(fileURLWithPath: "/tmp/uc-transcribe-fantasma"))
        #expect(await service.pendingCleanupCount == 1)
    }

    @Test("el segundo dictado del mismo móvil recibe busy, y cerrar la conexión libera el turno")
    func busyPerDevice() async throws {
        let service = try makeService(
            toolchain: MobileTranscriptionToolchain(
                whisperCLI: URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli"),
                ffmpeg: nil,
                ffprobe: nil
            ),
            model: URL(fileURLWithPath: "/m.bin"),
            runner: RecordingRunner(holdForever: true),
            limits: MobileTranscriptionLimits(perDeviceLimit: 1, totalLimit: 2)
        )
        let audio = WAVFixture(seconds: 1).data.base64EncodedString()
        let connectionID = UUID()
        let primero = Task {
            try await service.transcribe(
                base64: audio,
                mime: "audio/wav",
                language: nil,
                device: "100.1.1.1",
                connectionID: connectionID,
                startedAt: ContinuousClock.now
            )
        }
        while await service.activeJobCount == 0 {
            await Task.yield()
        }
        var capturado: MobileTranscriptionError?
        do {
            _ = try await service.transcribe(
                base64: audio,
                mime: "audio/wav",
                language: nil,
                device: "100.1.1.1",
                connectionID: nil,
                startedAt: ContinuousClock.now
            )
        } catch let error as MobileTranscriptionError {
            capturado = error
        }
        #expect(capturado == .busy)

        // Cerrar la conexión mata su dictado, y el móvil no recibe texto de una llamada cortada.
        await service.cancel(connectionID: connectionID)
        var cortado: MobileTranscriptionError?
        do {
            _ = try await primero.value
        } catch let error as MobileTranscriptionError {
            cortado = error
        }
        #expect(cortado?.code == "io_failed")
        #expect(await service.activeJobCount == 0)
    }
}
