import Foundation

/// Language Whisper is told to expect; Spanish unless changed in the box.
enum UniConnectDictationLanguage: String, CaseIterable, Identifiable, Sendable {
    case spanish = "es"
    case english = "en"
    /// Whisper detects it; slower to settle on short clips.
    case automatic = "auto"

    var id: String { rawValue }

    /// Code passed to Whisper; `nil` asks it to detect the language.
    var whisperCode: String? {
        self == .automatic ? nil : rawValue
    }

    /// Name shown in the box's menu.
    var title: String {
        switch self {
        case .spanish:
            return String(localized: "uniconnect.dictation.language.es", defaultValue: "Español")
        case .english:
            return String(localized: "uniconnect.dictation.language.en", defaultValue: "Inglés")
        case .automatic:
            return String(localized: "uniconnect.dictation.language.auto", defaultValue: "Detectar idioma")
        }
    }
}
