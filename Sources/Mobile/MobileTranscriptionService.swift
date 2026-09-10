import Foundation
import os

private let mobileTranscribeLog = Logger(subsystem: "com.unixcision.uniconnect", category: "mobile-transcribe")

/// Servicio de `transcribe.v1`: recibe el clip del móvil, lo transcribe con whisper.cpp en
/// este equipo y devuelve solo el texto.
///
/// Guarda el aforo (una transcripción por dispositivo y dos en el equipo) y los trabajos
/// vivos, para poder matarlos cuando la conexión del móvil se cierra. El trabajo en sí corre
/// en tareas sueltas, fuera de este actor y fuera del hilo principal, para que dos dictados
/// a la vez no se turnen; aquí solo se apunta quién está corriendo.
///
/// El motor es `whisper-cli` por proceso, no `whisper-server`. Un servidor no avisa de que ya
/// escucha (su línea de arranque se queda en el búfer de salida cuando no hay terminal
/// delante), así que habría que sondear el puerto, y el motor por proceso resuelve un dictado
/// de doce segundos en menos de dos, carga del modelo incluida. Es también la decisión que ya
/// está tomada en la edición de Linux.
actor MobileTranscriptionService {
    private struct RunningJob {
        let connectionID: UUID?
        let task: Task<MobileTranscriptionOutcome, any Error>
    }

    private let limits: MobileTranscriptionLimits
    private let workspace: MobileTranscriptionWorkspace
    private let resolveToolchain: @Sendable () -> MobileTranscriptionToolchain
    private let resolveModel: @Sendable () -> URL?
    private let runner: any MobileTranscriptionProcessRunning
    private let clock: any Clock<Duration>
    private let threads: Int
    private var admission: MobileTranscriptionAdmission
    private var jobs: [UUID: RunningJob] = [:]
    private var didSweep = false
    /// Directorios que el sistema de archivos se negó a borrar; se reintentan en el siguiente
    /// dictado, porque mientras este proceso viva el barrido no los toca (su pid sigue vivo).
    private var pendingCleanup: [URL] = []
    /// Conexiones cerradas hace poco. Una conexión puede caerse mientras su petición todavía
    /// va de camino, y entonces `cancel(connectionID:)` no encuentra ningún trabajo que matar;
    /// recordarlas evita que ese dictado arranque huérfano y ocupe turno hasta agotar el plazo.
    private var cancelledConnections: [UUID] = []

    /// Cuántas conexiones cerradas se recuerdan; de sobra para el trasiego de un móvil.
    private static let rememberedCancellations = 64

    /// - Parameters:
    ///   - limits: Límites del contrato; los tests los hacen pequeños.
    ///   - workspace: Carpeta privada de trabajo.
    ///   - resolveToolchain: Búsqueda de binarios, repetida en cada llamada por si el usuario
    ///     instala Homebrew con UniConnect ya abierto.
    ///   - resolveModel: Elección de modelo, por el mismo motivo.
    ///   - runner: Costura de proceso.
    ///   - clock: Reloj del plazo.
    ///   - threads: Hilos del motor.
    init(
        limits: MobileTranscriptionLimits = MobileTranscriptionLimits(),
        workspace: MobileTranscriptionWorkspace = MobileTranscriptionWorkspace(),
        resolveToolchain: @escaping @Sendable () -> MobileTranscriptionToolchain = { MobileTranscriptionToolchain.resolve() },
        resolveModel: @escaping @Sendable () -> URL? = { MobileWhisperModelCatalog().preferredModel() },
        runner: any MobileTranscriptionProcessRunning = MobileTranscriptionProcessRunner(),
        clock: any Clock<Duration> = ContinuousClock(),
        threads: Int = MobileWhisperCLICommand.threadCount(cores: ProcessInfo.processInfo.activeProcessorCount)
    ) {
        self.limits = limits
        self.workspace = workspace
        self.resolveToolchain = resolveToolchain
        self.resolveModel = resolveModel
        self.runner = runner
        self.clock = clock
        self.threads = threads
        self.admission = MobileTranscriptionAdmission(
            perDevice: limits.perDeviceLimit,
            total: limits.totalLimit
        )
    }

    /// Transcribe un clip recién llegado por la RPC.
    ///
    /// - Parameters:
    ///   - base64: Campo `audio` tal y como llegó.
    ///   - mime: Campo `mime`.
    ///   - language: Campo `language`.
    ///   - device: Dirección aprobada del móvil; manda el aforo por dispositivo.
    ///   - connectionID: Conexión que hace la llamada, para poder matar el trabajo si cuelga.
    ///   - startedAt: Instante de entrada de la RPC; de ahí salen el presupuesto y `took_ms`.
    /// - Returns: Texto, motor, duración medida y lo que tardó el equipo.
    /// - Throws: ``MobileTranscriptionError``.
    func transcribe(
        base64: String?,
        mime: String?,
        language: String?,
        device: String?,
        connectionID: UUID?,
        startedAt: ContinuousClock.Instant
    ) async throws -> MobileTranscriptionOutcome {
        sweepOnceAtStart()
        retryPendingCleanup()
        let toolchain = resolveToolchain()
        guard toolchain.whisperCLI != nil else {
            throw MobileTranscriptionError.unsupported(Self.noEngineMessage)
        }
        guard let model = resolveModel() else {
            throw MobileTranscriptionError.unsupported(Self.noModelMessage)
        }
        let request = try limits.validate(base64: base64, mime: mime, language: language, device: device)
        guard admission.admit(device: device) else {
            throw MobileTranscriptionError.busy
        }
        defer { admission.release(device: device) }

        let job = MobileTranscriptionJob(
            limits: limits,
            workspace: workspace,
            toolchain: toolchain,
            model: model,
            runner: runner,
            clock: clock,
            threads: threads,
            onCleanupFailure: { [weak self] directory in
                Task { await self?.recordLeftover(directory) }
            }
        )
        let remaining = limits.workingBudget - (ContinuousClock.now - startedAt)
        let jobID = UUID()
        let task = Task.detached { try await job.run(request: request, remaining: remaining) }
        jobs[jobID] = RunningJob(connectionID: connectionID, task: task)
        defer { jobs.removeValue(forKey: jobID) }
        // La conexión pudo cerrarse mientras esta petición venía de camino: entonces el aviso
        // llegó antes de que hubiera nada registrado y hay que atenderlo ahora.
        if let connectionID, cancelledConnections.contains(connectionID) {
            task.cancel()
        }
        do {
            // La tarea es suelta a propósito, para que dos dictados no se turnen en el actor;
            // esto vuelve a atar su vida a la de quien llama, que si no seguiría corriendo.
            let outcome = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            return MobileTranscriptionOutcome(
                text: outcome.text,
                engine: outcome.engine,
                seconds: outcome.seconds,
                tookMs: Self.milliseconds(since: startedAt)
            )
        } catch let error as MobileTranscriptionError {
            throw error
        } catch is CancellationError {
            throw MobileTranscriptionError.ioFailed(Self.cancelledMessage)
        } catch {
            throw MobileTranscriptionError.ioFailed(Self.ioFailedMessage)
        }
    }

    /// Mata los dictados de una conexión que ya no está.
    ///
    /// Un móvil que se va, o un dispositivo al que se le retira la aprobación, cierran la
    /// conexión; a partir de ahí el texto no le llegaría a nadie y el equipo no tiene por qué
    /// seguir gastando núcleos en producirlo.
    ///
    /// - Parameter connectionID: Conexión que se acaba de cerrar.
    func cancel(connectionID: UUID) {
        remember(cancelled: connectionID)
        for job in jobs.values where job.connectionID == connectionID {
            job.task.cancel()
        }
    }

    /// Apunta un directorio de trabajo que no se pudo borrar.
    ///
    /// El dictado ya se respondió: perder la limpieza no es motivo para tirar un texto que el
    /// usuario acaba de dictar. Queda anotado para reintentarlo, y la anotación no lleva ni el
    /// audio ni el texto, solo la ruta del directorio.
    ///
    /// - Parameter directory: Directorio que sigue en el disco.
    func recordLeftover(_ directory: URL) {
        guard !pendingCleanup.contains(directory) else { return }
        pendingCleanup.append(directory)
        mobileTranscribeLog.warning(
            "mobile transcribe could not delete its work directory; retrying on the next dictation"
        )
    }

    /// Directorios pendientes de borrar; los tests lo consultan.
    var pendingCleanupCount: Int {
        pendingCleanup.count
    }

    private func retryPendingCleanup() {
        guard !pendingCleanup.isEmpty else { return }
        pendingCleanup.removeAll { workspace.remove($0) }
    }

    private func remember(cancelled connectionID: UUID) {
        guard !cancelledConnections.contains(connectionID) else { return }
        cancelledConnections.append(connectionID)
        let excess = cancelledConnections.count - Self.rememberedCancellations
        if excess > 0 {
            cancelledConnections.removeFirst(excess)
        }
    }

    /// Trabajos vivos ahora mismo.
    var activeJobCount: Int {
        jobs.count
    }

    /// Borra en el primer uso lo que dejó en el disco un cierre a la fuerza anterior.
    ///
    /// Va aquí y no en el arranque de la app porque recorre un directorio, y en un equipo que
    /// nunca dicte ese trabajo no llega a hacerse nunca.
    private func sweepOnceAtStart() {
        guard !didSweep else { return }
        didSweep = true
        workspace.sweepOrphans()
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        let components = elapsed.components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }

    private static var noEngineMessage: String {
        String(
            localized: "uniconnect.mobile.transcribe.noEngine",
            defaultValue: "Este equipo no tiene instalado el motor de transcripción."
        )
    }

    private static var noModelMessage: String {
        String(
            localized: "uniconnect.mobile.transcribe.noModel",
            defaultValue: "Este equipo no tiene ningún modelo de transcripción instalado."
        )
    }

    private static var ioFailedMessage: String {
        String(
            localized: "uniconnect.mobile.transcribe.ioFailed",
            defaultValue: "No se pudo transcribir el audio en el equipo."
        )
    }

    private static var cancelledMessage: String {
        String(
            localized: "uniconnect.mobile.transcribe.cancelled",
            defaultValue: "La transcripción se canceló."
        )
    }
}
