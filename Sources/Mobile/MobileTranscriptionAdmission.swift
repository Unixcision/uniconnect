import Foundation

/// Control de aforo de `transcribe.v1`: una transcripción viva por dispositivo y dos en el
/// equipo. Es un valor puro; el actor del servicio lo guarda y lo muta bajo su aislamiento.
struct MobileTranscriptionAdmission: Equatable, Sendable {
    /// Transcripciones vivas por dispositivo.
    private(set) var activeByDevice: [String: Int] = [:]
    private let perDevice: Int
    private let total: Int

    /// - Parameters:
    ///   - perDevice: Máximo por móvil.
    ///   - total: Máximo en el equipo.
    init(perDevice: Int, total: Int) {
        self.perDevice = perDevice
        self.total = total
    }

    /// Transcripciones vivas en total.
    var activeCount: Int {
        activeByDevice.values.reduce(0, +)
    }

    /// Reserva un hueco.
    ///
    /// - Parameter device: Dirección del móvil; `nil` se agrupa en una clave común para que
    ///   una llamada sin transporte tampoco pueda saltarse el aforo.
    /// - Returns: `true` si había hueco; `false` significa `busy`.
    mutating func admit(device: String?) -> Bool {
        let key = Self.key(device)
        guard activeCount < total, activeByDevice[key, default: 0] < perDevice else {
            return false
        }
        activeByDevice[key, default: 0] += 1
        return true
    }

    /// Libera el hueco reservado por ``admit(device:)``.
    mutating func release(device: String?) {
        let key = Self.key(device)
        guard let current = activeByDevice[key] else { return }
        if current <= 1 {
            activeByDevice.removeValue(forKey: key)
        } else {
            activeByDevice[key] = current - 1
        }
    }

    private static func key(_ device: String?) -> String {
        let trimmed = device?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "-" : trimmed
    }
}
