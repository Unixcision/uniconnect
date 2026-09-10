import Foundation
import os

/// Lanza los procesos hijos de la transcripción y devuelve lo que escribieron.
///
/// El plazo no vive aquí: quien llama corre esta tarea contra un reloj y la cancela cuando el
/// presupuesto se agota o el móvil cuelga, y esa cancelación mata al hijo a través de
/// ``MobileTranscriptionProcessHandle``. Las dos tuberías se vacían en tareas aparte porque un
/// hijo que llene la suya se quedaría bloqueado escribiendo mientras el padre lo espera.
struct MobileTranscriptionProcessRunner: MobileTranscriptionProcessRunning {
    /// Espera entre `SIGTERM` y `SIGKILL` cuando hay que matar al hijo.
    let escalation: Duration
    /// Reloj de esa espera.
    let clock: any Clock<Duration>

    /// - Parameters:
    ///   - escalation: Margen que se le da al hijo para morir por las buenas.
    ///   - clock: Reloj de esa espera; los tests pasan uno virtual.
    init(escalation: Duration = .seconds(2), clock: any Clock<Duration> = ContinuousClock()) {
        self.escalation = escalation
        self.clock = clock
    }

    /// Ejecuta un programa y espera a que termine.
    ///
    /// - Parameters:
    ///   - executable: Ruta absoluta del binario.
    ///   - arguments: Argumentos, ya construidos por el tipo de orden correspondiente.
    /// - Returns: Código de salida y las dos salidas completas.
    /// - Throws: `CancellationError` si la tarea se cancela, o el error de `Process.run()`.
    func run(executable: URL, arguments: [String]) async throws -> MobileTranscriptionProcessResult {
        let handle = MobileTranscriptionProcessHandle(escalation: escalation, clock: clock)
        let result = try await withTaskCancellationHandler {
            try await Self.spawn(executable: executable, arguments: arguments, handle: handle)
        } onCancel: {
            handle.terminate()
        }
        if handle.isCancelled {
            throw CancellationError()
        }
        return result
    }

    private struct SpawnState {
        var standardOutput: Data?
        var standardError: Data?
        var didTerminate = false
        var exitStatus: Int32?
        var didResume = false
    }

    private static func spawn(
        executable: URL,
        arguments: [String],
        handle: MobileTranscriptionProcessHandle
    ) async throws -> MobileTranscriptionProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // El hijo no hereda ni el entorno ni la entrada del usuario: `ffmpeg` sin `stdin` se
        // queda esperando para siempre, y un `PATH` heredado cambiaría qué binario resuelve.
        process.standardInput = FileHandle.nullDevice
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe
        let standardOutputDescriptor = standardOutputPipe.fileHandleForReading.fileDescriptor
        let standardErrorDescriptor = standardErrorPipe.fileHandleForReading.fileDescriptor

        return try await withCheckedThrowingContinuation { continuation in
            // Carve-out de lock: los dos lectores y el `terminationHandler` corren en callbacks
            // síncronos y compiten por reanudar la continuación exactamente una vez.
            let state = OSAllocatedUnfairLock(initialState: SpawnState())

            @Sendable func complete(_ mutate: @Sendable (inout SpawnState) -> Void) {
                let result = state.withLock { current -> MobileTranscriptionProcessResult? in
                    mutate(&current)
                    guard !current.didResume,
                          let standardOutput = current.standardOutput,
                          let standardError = current.standardError,
                          current.didTerminate else {
                        return nil
                    }
                    current.didResume = true
                    return MobileTranscriptionProcessResult(
                        exitStatus: current.exitStatus ?? -1,
                        standardOutput: standardOutput,
                        standardError: standardError
                    )
                }
                guard let result else { return }
                handle.finish()
                continuation.resume(returning: result)
            }

            @Sendable func fail(_ error: any Error) {
                let won = state.withLock { current -> Bool in
                    guard !current.didResume else { return false }
                    current.didResume = true
                    return true
                }
                guard won else { return }
                handle.finish()
                continuation.resume(throwing: error)
            }

            Task.detached {
                let data = Self.readToEnd(fileDescriptor: standardOutputDescriptor)
                complete { $0.standardOutput = data }
            }
            Task.detached {
                let data = Self.readToEnd(fileDescriptor: standardErrorDescriptor)
                complete { $0.standardError = data }
            }
            process.terminationHandler = { finished in
                let status = finished.terminationStatus
                complete {
                    $0.didTerminate = true
                    $0.exitStatus = status
                }
            }
            do {
                try process.run()
            } catch {
                try? standardOutputPipe.fileHandleForWriting.close()
                try? standardErrorPipe.fileHandleForWriting.close()
                fail(error)
                return
            }
            // Los extremos de escritura se cierran en el padre para que los lectores vean el
            // fin de archivo cuando el hijo cierre los suyos.
            try? standardOutputPipe.fileHandleForWriting.close()
            try? standardErrorPipe.fileHandleForWriting.close()
            if !handle.attach(process) {
                fail(CancellationError())
            }
        }
    }

    private static func readToEnd(fileDescriptor: Int32) -> Data {
        let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        return (try? handle.readToEnd()) ?? Data()
    }
}
