import Foundation

/// Lanza los procesos hijos de la transcripción y devuelve lo que escribieron.
///
/// El plazo no vive aquí: quien llama corre esta tarea contra un reloj y la cancela cuando el
/// presupuesto se agota o el móvil cuelga, y esa cancelación mata al grupo del hijo a través
/// de ``MobileTranscriptionProcessHandle``. Las dos tuberías se vacían a la vez que se espera
/// al hijo, porque un hijo que llene la suya se quedaría bloqueado escribiendo mientras el
/// padre lo espera. Las tres esperas son bloqueantes, así que corren en una cola aparte y no
/// en el grupo de hilos de las tareas.
struct MobileTranscriptionProcessRunner: MobileTranscriptionProcessRunning {
    /// Cola de las esperas bloqueantes (leer hasta el fin de archivo y recoger al hijo). Es
    /// entrega de eventos, no protección de estado: por eso es concurrente, ya que recoger al
    /// hijo antes de vaciar sus tuberías sería un abrazo mortal.
    private static let waitQueue = DispatchQueue(
        label: "com.unixcision.uniconnect.mobile.transcribe.wait",
        attributes: .concurrent
    )

    /// Espera entre `SIGTERM` y `SIGKILL` cuando hay que matar al hijo.
    let escalation: Duration
    /// Reloj de esa espera.
    let clock: any Clock<Duration>
    /// Arranque del hijo con sesión propia.
    let spawner: MobileTranscriptionSpawner

    /// - Parameters:
    ///   - escalation: Margen que se le da al hijo para morir por las buenas.
    ///   - clock: Reloj de esa espera; los tests pasan uno virtual.
    ///   - spawner: Arranque del hijo.
    init(
        escalation: Duration = .seconds(2),
        clock: any Clock<Duration> = ContinuousClock(),
        spawner: MobileTranscriptionSpawner = MobileTranscriptionSpawner()
    ) {
        self.escalation = escalation
        self.clock = clock
        self.spawner = spawner
    }

    /// Ejecuta un programa y espera a que termine.
    ///
    /// - Parameters:
    ///   - executable: Ruta absoluta del binario.
    ///   - arguments: Argumentos, ya construidos por el tipo de orden correspondiente.
    /// - Returns: Código de salida y las dos salidas completas.
    /// - Throws: `CancellationError` si la tarea se cancela, o
    ///   ``MobileTranscriptionError/ioFailed(_:)`` si el hijo no llegó a arrancar.
    func run(executable: URL, arguments: [String]) async throws -> MobileTranscriptionProcessResult {
        let handle = MobileTranscriptionProcessHandle(escalation: escalation, clock: clock)
        let result = try await withTaskCancellationHandler {
            try await collect(executable: executable, arguments: arguments, handle: handle)
        } onCancel: {
            handle.terminate()
        }
        if handle.isCancelled {
            throw CancellationError()
        }
        return result
    }

    private func collect(
        executable: URL,
        arguments: [String],
        handle: MobileTranscriptionProcessHandle
    ) async throws -> MobileTranscriptionProcessResult {
        let child = try spawner.spawn(executable: executable, arguments: arguments)
        // Si la cancelación se adelantó al arranque, el grupo ya ha recibido la señal; aun así
        // hay que vaciar y recoger al hijo para no dejar un zombi detrás.
        let didAttach = handle.attach(child.identifier)
        async let standardOutput = Self.readToEnd(fileDescriptor: child.standardOutputDescriptor)
        async let standardError = Self.readToEnd(fileDescriptor: child.standardErrorDescriptor)
        let exitStatus = await Self.wait(for: child.identifier)
        let result = MobileTranscriptionProcessResult(
            exitStatus: exitStatus,
            standardOutput: await standardOutput,
            standardError: await standardError
        )
        // A partir de aquí el sistema puede reutilizar el identificador, así que la escalada a
        // `SIGKILL` no debe llegar tarde a un proceso que ya no es este.
        handle.finish()
        guard didAttach else { throw CancellationError() }
        return result
    }

    private static func readToEnd(fileDescriptor: Int32) async -> Data {
        await withCheckedContinuation { continuation in
            waitQueue.async {
                let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
                defer { try? handle.close() }
                continuation.resume(returning: (try? handle.readToEnd()) ?? Data())
            }
        }
    }

    private static func wait(for identifier: pid_t) async -> Int32 {
        await withCheckedContinuation { continuation in
            waitQueue.async {
                var raw: Int32 = 0
                while waitpid(identifier, &raw, 0) < 0 {
                    guard errno == EINTR else {
                        continuation.resume(returning: -1)
                        return
                    }
                }
                continuation.resume(returning: exitStatus(raw: raw))
            }
        }
    }

    /// Traduce lo que devuelve `waitpid`.
    ///
    /// - Parameter raw: Estado tal cual lo dejó `waitpid`.
    /// - Returns: El código de salida, o el número de señal en negativo si al hijo lo mataron.
    static func exitStatus(raw: Int32) -> Int32 {
        let signal = raw & 0x7F
        if signal == 0 {
            return (raw >> 8) & 0xFF
        }
        return -signal
    }
}
