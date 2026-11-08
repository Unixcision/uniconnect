import Foundation

/// Why a window could not switch to the requested user (`run_as_failed.cause`, `run-as.v1`).
///
/// The window stays created with its shell and without an agent. No case carries the password
/// or anything typed: only the cause and a fixed Spanish message.
enum UniConnectRunAsFailure: String, Error, Equatable, Sendable {
    case passwordIncorrect = "password_incorrect"
    case notAllowed = "not_allowed"
    case userNotFound = "user_not_found"
    case timeout
    case wrongUser = "wrong_user"
    /// The switch ended without any of the causes above.
    case failed

    /// What the phone and the desktop show.
    var message: String {
        switch self {
        case .passwordIncorrect:
            return String(
                localized: "uniconnect.runAs.failure.passwordIncorrect",
                defaultValue: "La contraseña no es correcta. La ventana se ha creado sin IA."
            )
        case .notAllowed:
            return String(
                localized: "uniconnect.runAs.failure.notAllowed",
                defaultValue: "Ese usuario no puede cambiar de usuario en esta máquina. La ventana se ha creado sin IA."
            )
        case .userNotFound:
            return String(
                localized: "uniconnect.runAs.failure.userNotFound",
                defaultValue: "Ese usuario no existe en esta máquina. La ventana se ha creado sin IA."
            )
        case .timeout:
            return String(
                localized: "uniconnect.runAs.failure.timeout",
                defaultValue: "El cambio de usuario no terminó a tiempo. La ventana se ha creado sin IA."
            )
        case .wrongUser:
            return String(
                localized: "uniconnect.runAs.failure.wrongUser",
                defaultValue: "La ventana no quedó con el usuario pedido, así que no se lanzó la IA."
            )
        case .failed:
            return String(
                localized: "uniconnect.runAs.failure.failed",
                defaultValue: "No se pudo cambiar de usuario. La ventana se ha creado sin IA."
            )
        }
    }
}
