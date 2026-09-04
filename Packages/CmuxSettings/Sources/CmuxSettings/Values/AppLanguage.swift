import Foundation

/// User-selected language for the UniConnect UI.
///
/// Raw values match the `AppleLanguages` BCP-47 identifiers stored on disk.
/// Vietnamese remains decodable for forward/backward compatibility even though
/// the current app bundle does not advertise a Vietnamese localization.
public enum AppLanguage: String, CaseIterable, Sendable, SettingCodable {
    case system, en, ar, bs, zhHans = "zh-Hans", zhHant = "zh-Hant", da, de, es, fr, it, ja, km, ko, nb, pl, ptBR = "pt-BR", ru, th, tr, uk, vi
}
