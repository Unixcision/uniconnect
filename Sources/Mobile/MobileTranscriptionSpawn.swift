import Foundation

/// Hijo recién arrancado con sesión propia: su identificador y los extremos de lectura de sus
/// dos salidas.
///
/// Al abrir sesión propia, el grupo de procesos del hijo tiene su mismo identificador, que es
/// lo que permite señalar al grupo entero (`kill(-pid, …)`) sin riesgo de alcanzar a nadie más.
struct MobileTranscriptionSpawn: Equatable, Sendable {
    /// Identificador del hijo, que es también el de su grupo.
    let identifier: pid_t
    /// Extremo de lectura de la salida estándar.
    let standardOutputDescriptor: Int32
    /// Extremo de lectura de la salida de error.
    let standardErrorDescriptor: Int32
}
