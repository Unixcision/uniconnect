import Foundation

/// Why a whole call was refused, as opposed to why one target did not proceed.
public enum RelaunchError: String, Sendable, Codable, Error {
    /// The plan's token no longer stands. Ask for a new plan.
    ///
    /// Never raised when recovering an operation that was already accepted: making a network cut
    /// between the close and its answer cost a new plan is exactly the lost work this contract
    /// exists to prevent.
    case tokenExpired = "token_caducado"
    /// The token does not belong to this device, this verb, or these targets.
    case tokenInvalid = "token_no_valido"
    /// No operation carries that identifier.
    case unknownOperation = "operacion_desconocida"
    /// The requested scope does not exist or cannot be resolved.
    case invalidScope = "alcance_no_valido"
}
