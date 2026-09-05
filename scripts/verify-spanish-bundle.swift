import Foundation

/// Exercises Foundation's lookup against a compiled bundle, not source metadata.
struct SpanishBundleVerification {
    static func main() throws {
        guard CommandLine.arguments.count == 2,
              let bundle = Bundle(path: CommandLine.arguments[1]) else {
            throw Failure.invalidBundle
        }
        guard bundle.developmentLocalization == "es",
              Set(bundle.localizations).subtracting(["Base"]) == ["es"] else {
            throw Failure.invalidLanguages
        }
        let samples = [
            ("common.cancel", "Cancelar"),
            ("language.spanish", "Español"),
            ("command.auth.signIn.title", "Iniciar sesión"),
        ]
        for (key, expected) in samples {
            guard bundle.localizedString(forKey: key, value: "MISSING", table: "Localizable") == expected else {
                throw Failure.unexpectedTranslation(key)
            }
        }
        let camera = bundle.localizedString(forKey: "NSCameraUsageDescription", value: "MISSING", table: "InfoPlist")
        guard camera == "Un programa en ejecución dentro de UniConnect desea usar tu cámara." else {
            throw Failure.unexpectedTranslation("NSCameraUsageDescription")
        }
        print("Catálogo compilado: solo español; búsquedas de interfaz y permisos correctas.")
    }

    private enum Failure: Error {
        case invalidBundle, invalidLanguages, unexpectedTranslation(String)
    }
}

try SpanishBundleVerification.main()
