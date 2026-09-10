import Foundation

/// Una transcripción de principio a fin: escribir el clip, medirlo, convertirlo si hace falta
/// y pasarlo por whisper.cpp.
///
/// No guarda estado entre llamadas ni toca el hilo principal, así que dos dictados corren a la
/// vez sin estorbarse. Todo el trabajo cabe en el presupuesto que le dan: el plazo corre
/// contra un reloj inyectado y, cuando salta, la cancelación mata al hijo que estuviera
/// corriendo. El directorio de la llamada se borra en todas las salidas.
struct MobileTranscriptionJob: Sendable {
    /// Límites del contrato.
    let limits: MobileTranscriptionLimits
    /// Carpeta privada de trabajo.
    let workspace: MobileTranscriptionWorkspace
    /// Binarios encontrados en este equipo.
    let toolchain: MobileTranscriptionToolchain
    /// Modelo elegido.
    let model: URL
    /// Costura de proceso.
    let runner: any MobileTranscriptionProcessRunning
    /// Reloj del plazo.
    let clock: any Clock<Duration>
    /// Hilos que se le piden al motor.
    let threads: Int
    /// Aviso de que un directorio de trabajo se quedó en el disco.
    let onCleanupFailure: @Sendable (URL) -> Void

    /// - Parameters:
    ///   - limits: Límites y presupuesto.
    ///   - workspace: Carpeta privada donde vive el audio.
    ///   - toolchain: Binarios resueltos.
    ///   - model: Modelo `.bin`.
    ///   - runner: Lanzador de procesos; los tests pasan uno falso.
    ///   - clock: Reloj del plazo; los tests pasan uno virtual.
    ///   - threads: Hilos del motor.
    ///   - onCleanupFailure: Se avisa con el directorio que el sistema de archivos se negó a
    ///     borrar, para que se reintente más tarde. No lleva ni el audio ni el texto.
    init(
        limits: MobileTranscriptionLimits,
        workspace: MobileTranscriptionWorkspace,
        toolchain: MobileTranscriptionToolchain,
        model: URL,
        runner: any MobileTranscriptionProcessRunning,
        clock: any Clock<Duration>,
        threads: Int,
        onCleanupFailure: @escaping @Sendable (URL) -> Void = { _ in }
    ) {
        self.limits = limits
        self.workspace = workspace
        self.toolchain = toolchain
        self.model = model
        self.runner = runner
        self.clock = clock
        self.threads = threads
        self.onCleanupFailure = onCleanupFailure
    }

    /// Nombre del motor que viaja al móvil, sin rutas del equipo.
    var engineName: String {
        "whisper.cpp/\(model.lastPathComponent)"
    }

    /// Transcribe un clip dentro del plazo que queda.
    ///
    /// - Parameters:
    ///   - request: Petición ya validada.
    ///   - remaining: Lo que queda del presupuesto de la llamada.
    /// - Returns: Texto, motor y duración medida; `took_ms` lo pone quien llama.
    /// - Throws: ``MobileTranscriptionError``.
    func run(request: MobileTranscriptionRequest, remaining: Duration) async throws -> MobileTranscriptionOutcome {
        guard remaining > .zero else {
            throw MobileTranscriptionError.ioFailed(Self.timeoutMessage)
        }
        return try await withThrowingTaskGroup(of: MobileTranscriptionOutcome.self) { group in
            group.addTask { try await self.transcribe(request) }
            group.addTask {
                // Retraso acotado y cancelable: es el plazo de la llamada, no un sondeo. Al
                // saltar, la salida del grupo cancela al hermano y eso mata al hijo vivo.
                try await self.clock.sleep(for: remaining)
                throw MobileTranscriptionError.ioFailed(Self.timeoutMessage)
            }
            do {
                guard let outcome = try await group.next() else {
                    throw MobileTranscriptionError.ioFailed(Self.ioFailedMessage)
                }
                group.cancelAll()
                return outcome
            } catch is CancellationError {
                throw MobileTranscriptionError.ioFailed(Self.cancelledMessage)
            }
        }
    }

    private func transcribe(_ request: MobileTranscriptionRequest) async throws -> MobileTranscriptionOutcome {
        let directory: URL
        do {
            directory = try workspace.makeCallDirectory()
        } catch {
            throw MobileTranscriptionError.ioFailed(Self.ioFailedMessage)
        }
        // Un borrado que el sistema de archivos rechaza deja el audio en el disco. Se avisa en
        // vez de dar la limpieza por hecha, y el dictado se responde igual: perder la limpieza
        // no es motivo para tirar un texto que el usuario acaba de dictar.
        defer {
            if !workspace.remove(directory) {
                onCleanupFailure(directory)
            }
        }

        let clip = directory.appendingPathComponent("clip.\(request.format.fileExtension)", isDirectory: false)
        try workspace.write(request.audio, to: clip)

        let prepared = try await prepare(request: request, clip: clip, in: directory)
        try limits.verify(seconds: prepared.seconds)

        let command = MobileWhisperCLICommand(
            model: model,
            audio: prepared.audio,
            language: request.language,
            threads: threads
        )
        guard let whisper = toolchain.whisperCLI else {
            throw MobileTranscriptionError.unsupported(Self.noEngineMessage)
        }
        let result = try await execute(executable: whisper, arguments: command.arguments)
        guard result.didSucceed else {
            throw MobileTranscriptionError.ioFailed(Self.ioFailedMessage)
        }
        return MobileTranscriptionOutcome(
            text: MobileWhisperTranscript(raw: result.standardOutputText).text,
            engine: engineName,
            seconds: prepared.seconds,
            tookMs: 0
        )
    }

    /// Audio listo para el motor y su duración medida.
    private struct PreparedAudio {
        let audio: URL
        let seconds: Double
    }

    /// Deja el clip en PCM de 16 bits, mono y 16 kHz, y mide su duración de verdad.
    ///
    /// La duración se comprueba en cuanto se conoce, antes de convertir y antes de arrancar el
    /// motor: un clip de una hora recomprimido cabe de sobra en los 3 MiB, y solo medirlo lo
    /// delata. El MIME no interviene en la medida en ningún momento.
    private func prepare(
        request: MobileTranscriptionRequest,
        clip: URL,
        in directory: URL
    ) async throws -> PreparedAudio {
        if let header = MobileWAVFormat.parse(request.audio) {
            try limits.verify(seconds: header.seconds)
            if header.isWhisperReady {
                return PreparedAudio(audio: clip, seconds: header.seconds)
            }
        } else if let ffprobe = toolchain.ffprobe {
            let probe = MobileAudioProbeCommand(input: clip)
            let result = try? await execute(executable: ffprobe, arguments: probe.arguments)
            if let result, result.didSucceed,
               let seconds = MobileAudioProbeCommand.seconds(from: result.standardOutputText) {
                try limits.verify(seconds: seconds)
            }
        }

        guard let ffmpeg = toolchain.ffmpeg else {
            throw MobileTranscriptionError.unsupported(Self.noConverterMessage)
        }
        let converted = directory.appendingPathComponent("clip-16k.wav", isDirectory: false)
        let conversion = MobileAudioConversionCommand(
            input: clip,
            output: converted,
            maximumSeconds: limits.maximumSeconds
        )
        let result = try await execute(executable: ffmpeg, arguments: conversion.arguments)
        guard result.didSucceed,
              let data = try? Data(contentsOf: converted, options: [.mappedIfSafe]),
              let header = MobileWAVFormat.parse(data),
              header.isWhisperReady else {
            throw MobileTranscriptionError.ioFailed(Self.ioFailedMessage)
        }
        // Un clip que llegó al techo de `-t` o de `-fs` sale con la duración pegada al tope, y
        // eso es `too_large`: mejor rechazarlo que transcribir un dictado cortado por la mitad.
        try limits.verify(seconds: header.seconds)
        return PreparedAudio(audio: converted, seconds: header.seconds)
    }

    private func execute(executable: URL, arguments: [String]) async throws -> MobileTranscriptionProcessResult {
        do {
            return try await runner.run(executable: executable, arguments: arguments)
        } catch is CancellationError {
            throw MobileTranscriptionError.ioFailed(Self.cancelledMessage)
        } catch let error as MobileTranscriptionError {
            throw error
        } catch {
            throw MobileTranscriptionError.ioFailed(Self.ioFailedMessage)
        }
    }

    private static var ioFailedMessage: String {
        String(
            localized: "uniconnect.mobile.transcribe.ioFailed",
            defaultValue: "No se pudo transcribir el audio en el equipo."
        )
    }

    private static var timeoutMessage: String {
        String(
            localized: "uniconnect.mobile.transcribe.timeout",
            defaultValue: "La transcripción tardó demasiado."
        )
    }

    private static var cancelledMessage: String {
        String(
            localized: "uniconnect.mobile.transcribe.cancelled",
            defaultValue: "La transcripción se canceló."
        )
    }

    private static var noEngineMessage: String {
        String(
            localized: "uniconnect.mobile.transcribe.noEngine",
            defaultValue: "Este equipo no tiene instalado el motor de transcripción."
        )
    }

    private static var noConverterMessage: String {
        String(
            localized: "uniconnect.mobile.transcribe.noConverter",
            defaultValue: "Este equipo no puede convertir este formato de audio."
        )
    }
}
