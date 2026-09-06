import Foundation

enum MobileTmuxAttachError: Error, LocalizedError, Equatable, Sendable {
    case locked
    case targetUnavailable
    case legacyTerminal
    case invalidSSHCredential
    case targetChanged
    case missingTmux
    case unsupportedTmux
    case missingSession

    var errorDescription: String? {
        switch self {
        case .locked:
            String(localized: "uniconnect.mobile.tmux.locked", defaultValue: "Desbloquea UniConnect para acceder a esta terminal.")
        case .targetUnavailable:
            String(localized: "uniconnect.mobile.tmux.targetUnavailable", defaultValue: "La terminal solicitada ya no está disponible.")
        case .legacyTerminal:
            String(localized: "uniconnect.mobile.tmux.legacyTerminal", defaultValue: "Esta terminal no tiene una sesión tmux compartida. Crea una terminal nueva para acceder desde el móvil.")
        case .invalidSSHCredential:
            String(localized: "uniconnect.mobile.tmux.invalidSSHCredential", defaultValue: "La conexión SSH guardada no tiene un destino válido. Revisa sus credenciales en UniConnect.")
        case .targetChanged:
            String(localized: "uniconnect.mobile.tmux.targetChanged", defaultValue: "La terminal o sus credenciales han cambiado. Vuelve a conectarte desde el móvil.")
        case .missingTmux:
            String(localized: "uniconnect.mobile.tmux.missing", defaultValue: "tmux no está disponible en el equipo de esta terminal.")
        case .unsupportedTmux:
            String(localized: "uniconnect.mobile.tmux.unsupportedVersion", defaultValue: "Esta versión de tmux no permite garantizar una conexión móvil independiente. Se requiere una versión estable entre 3.2 y 3.7.")
        case .missingSession:
            String(localized: "uniconnect.mobile.tmux.sessionMissing", defaultValue: "La sesión tmux guardada ya no existe. No se ha creado otra terminal ni reiniciado ninguna IA.")
        }
    }
}
