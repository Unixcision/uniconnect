import Foundation

/// Persisted language preference for the Spanish-only UniConnect UI.
///
/// Raw values match the `AppleLanguages` BCP-47 identifiers stored on disk.
/// Legacy values remain decodable so older settings can be imported. They all
/// resolve to Spanish; they are not additional supported interface languages.
public enum AppLanguage: String, CaseIterable, Sendable, SettingCodable {
    case system, en, ar, bs, zhHans = "zh-Hans", zhHant = "zh-Hant", da, de, es, fr, it, ja, km, ko, nb, pl, ptBR = "pt-BR", ru, th, tr, uk, vi

    /// The only language offered by this product.
    public static let allCases: [AppLanguage] = [.es]

    /// The supported language to use when applying a current or legacy value.
    public var effectiveLanguage: AppLanguage { .es }
}
