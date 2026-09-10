import Darwin
import Foundation

/// Arranca un hijo de la transcripción en su propia sesión.
///
/// `Process` no ofrece forma de abrir sesión para el hijo, y sin ella el hijo hereda el grupo
/// de UniConnect: no habría ningún grupo al que señalar al cancelar, y matar solo al padre
/// dejaría vivo cualquier nieto. Con `posix_spawn` y `POSIX_SPAWN_SETSID` el hijo queda como
/// líder de su propia sesión, así que su grupo lleva su mismo identificador y una señal al
/// grupo alcanza al hijo y a toda su descendencia, y a nadie más.
struct MobileTranscriptionSpawner: Sendable {
    /// Entorno mínimo del hijo.
    ///
    /// Ni hereda el del usuario ni su entrada estándar: un `PATH` heredado cambiaría qué
    /// binario resuelve cada herramienta, y `ffmpeg` sin entrada se queda esperando para
    /// siempre, que es como un hijo suelto agota el presupuesto entero.
    static let minimalEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]

    /// Arranca el programa.
    ///
    /// - Parameters:
    ///   - executable: Ruta absoluta del binario.
    ///   - arguments: Argumentos, sin el nombre del programa.
    ///   - environment: Entorno del hijo.
    /// - Returns: El hijo y los extremos de lectura de sus salidas, que quien llama debe cerrar.
    /// - Throws: ``MobileTranscriptionError/ioFailed(_:)`` si no se pudo arrancar.
    func spawn(
        executable: URL,
        arguments: [String],
        environment: [String: String] = MobileTranscriptionSpawner.minimalEnvironment
    ) throws -> MobileTranscriptionSpawn {
        var standardOutputPipe: [Int32] = [-1, -1]
        var standardErrorPipe: [Int32] = [-1, -1]
        guard pipe(&standardOutputPipe) == 0 else { throw Self.failure }
        guard pipe(&standardErrorPipe) == 0 else {
            close(standardOutputPipe[0])
            close(standardOutputPipe[1])
            throw Self.failure
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        // Sesión propia: sin esto no hay grupo que señalar al cancelar.
        posix_spawnattr_setflags(&attributes, Int16(Self.setSessionFlag | Self.closeInheritedDescriptorsFlag))
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, standardOutputPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, standardErrorPipe[1], 2)

        var identifier: pid_t = -1
        let status = Self.withCStringArray([executable.path] + arguments) { argv in
            Self.withCStringArray(environment.map { "\($0.key)=\($0.value)" }) { envp in
                posix_spawn(&identifier, executable.path, &actions, &attributes, argv, envp)
            }
        }
        // Los extremos de escritura son del hijo: en el padre se cierran ya, para que los
        // lectores vean el fin de archivo cuando el hijo cierre los suyos.
        close(standardOutputPipe[1])
        close(standardErrorPipe[1])
        guard status == 0, identifier > 1 else {
            close(standardOutputPipe[0])
            close(standardErrorPipe[0])
            throw Self.failure
        }
        return MobileTranscriptionSpawn(
            identifier: identifier,
            standardOutputDescriptor: standardOutputPipe[0],
            standardErrorDescriptor: standardErrorPipe[0]
        )
    }

    /// `POSIX_SPAWN_SETSID`: el hijo abre sesión propia y con ella su propio grupo.
    private static let setSessionFlag: Int32 = 0x0400

    /// `POSIX_SPAWN_CLOEXEC_DEFAULT`: el hijo no hereda ningún descriptor salvo los tres que
    /// se le montan aquí, así que el motor nunca se queda con un socket del móvil en la mano.
    private static let closeInheritedDescriptorsFlag: Int32 = 0x4000

    private static var failure: MobileTranscriptionError {
        .ioFailed(String(
            localized: "uniconnect.mobile.transcribe.ioFailed",
            defaultValue: "No se pudo transcribir el audio en el equipo."
        ))
    }

    /// Presta un vector de cadenas C terminado en `nil` mientras dure el bloque.
    private static func withCStringArray<Result>(
        _ values: [String],
        _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        var pointers: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
        pointers.append(nil)
        defer {
            for pointer in pointers where pointer != nil {
                free(pointer)
            }
        }
        return body(&pointers)
    }
}
