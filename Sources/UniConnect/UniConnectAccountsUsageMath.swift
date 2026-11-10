import Foundation

/// The shared rules of «Uso por cuenta» (`accounts-v1` §4.1) at one instant: labels, resets,
/// age, rate and projection. Same formulas as Linux and Android.
struct UniConnectAccountsUsageMath {
    /// What one limit shows now.
    struct LimitReading: Equatable {
        /// The percentage to draw: 0 when the window already reset after the observation.
        let percent: Double
        /// Whether `resets_at` has passed since it was observed.
        let wasReset: Bool
    }

    /// Rate and projection of one limit inside its current window.
    struct Projection: Equatable {
        /// Percentage points per day.
        let perDay: Double
        /// Where it would be at `resets_at` at this rate (may exceed 100).
        let atReset: Double
        /// When it would reach 100 %, if it does before the reset.
        let exhaustion: Date?
    }

    let now: Date

    /// The account's color index in `paleta.json`: FNV-1a 32 bits of the lowercased email, mod 8.
    static func colorIndex(email: String) -> Int {
        var hash: UInt32 = 0x811C_9DC5
        for byte in email.lowercased().utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return Int(hash % 8)
    }

    /// `paleta.json` colors as RGB hex, by index.
    static let paletteHex: [UInt32] = [0xEB5757, 0xF2994A, 0x27AE60, 0x2F80ED, 0x9B51E0, 0x00A3A3, 0xC9A227, 0xE05BA8]
    /// Color for rows without an email.
    static let neutralHex: UInt32 = 0x8E8E93

    /// «5 horas», «Semana», «Semana · Opus»… for a limit id and window.
    static func label(id: String, windowMinutes: Int?) -> String {
        switch id {
        case "five_hour":
            return String(localized: "uniconnect.accounts.limit.fiveHour", defaultValue: "5 horas")
        case "seven_day":
            return String(localized: "uniconnect.accounts.limit.week", defaultValue: "Semana")
        case "seven_day_opus":
            return String(localized: "uniconnect.accounts.limit.weekOpus", defaultValue: "Semana · Opus")
        case "seven_day_sonnet":
            return String(localized: "uniconnect.accounts.limit.weekSonnet", defaultValue: "Semana · Sonnet")
        case "seven_day_fable":
            return String(localized: "uniconnect.accounts.limit.weekFable", defaultValue: "Semana · Fable")
        default:
            break
        }
        switch windowMinutes {
        case 300?:
            return String(localized: "uniconnect.accounts.limit.fiveHour", defaultValue: "5 horas")
        case 10_080?:
            return String(localized: "uniconnect.accounts.limit.week", defaultValue: "Semana")
        case let minutes? where minutes > 0:
            let format = String(localized: "uniconnect.accounts.limit.hours", defaultValue: "%lld h")
            return String.localizedStringWithFormat(format, Int64(max(1, minutes / 60)))
        default:
            return id
        }
    }

    /// The percentage to draw now, and whether the window reset since it was observed.
    func reading(_ limit: UniConnectAccountsSnapshot.Limit) -> LimitReading {
        if let resetsAt = limit.resetsAt, resetsAt <= now {
            return LimitReading(percent: 0, wasReset: true)
        }
        return LimitReading(percent: limit.usedPercent, wasReset: false)
    }

    /// Whether an observation is older than one hour (shown in amber).
    func isOld(_ observedAt: Date) -> Bool {
        now.timeIntervalSince(observedAt) > 3_600
    }

    /// Rate and projection from the samples inside the current window (§4.1), or `nil`.
    ///
    /// Needs `resets_at`, `window_minutes` and two samples at least 30 minutes apart.
    func projection(
        limit: UniConnectAccountsSnapshot.Limit,
        observedAt: Date,
        history: [UniConnectAccountsSnapshot.HistoryPoint]
    ) -> Projection? {
        guard let resetsAt = limit.resetsAt, resetsAt > now,
              let windowMinutes = limit.windowMinutes, windowMinutes > 0 else { return nil }
        let windowStart = resetsAt.addingTimeInterval(-Double(windowMinutes) * 60)
        var samples = history.compactMap { point -> (Date, Double)? in
            guard point.at >= windowStart, let value = point.limits[limit.id] else { return nil }
            return (point.at, value)
        }
        if observedAt >= windowStart, !samples.contains(where: { $0.0 == observedAt }) {
            samples.append((observedAt, limit.usedPercent))
        }
        samples.sort { $0.0 < $1.0 }
        guard let first = samples.first, let last = samples.last else { return nil }
        let hours = last.0.timeIntervalSince(first.0) / 3_600
        guard hours >= 0.5 else { return nil }
        let perHour = (last.1 - first.1) / hours
        let hoursToReset = resetsAt.timeIntervalSince(now) / 3_600
        let current = limit.usedPercent
        let atReset = current + perHour * hoursToReset
        var exhaustion: Date?
        if atReset >= 100, perHour > 0 {
            exhaustion = now.addingTimeInterval((100 - current) / perHour * 3_600)
        }
        return Projection(perDay: perHour * 24, atReset: atReset, exhaustion: exhaustion)
    }

    /// «2 d 3 h», «3 h 20 min» or «12 min» until `date`.
    func remaining(until date: Date) -> String {
        let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
        let days = minutes / 1_440
        let hours = (minutes % 1_440) / 60
        let mins = minutes % 60
        if days > 0 {
            let format = String(localized: "uniconnect.accounts.remaining.daysHours", defaultValue: "%1$lld d %2$lld h")
            return String.localizedStringWithFormat(format, Int64(days), Int64(hours))
        }
        if hours > 0 {
            let format = String(localized: "uniconnect.accounts.remaining.hoursMinutes", defaultValue: "%1$lld h %2$lld min")
            return String.localizedStringWithFormat(format, Int64(hours), Int64(mins))
        }
        let format = String(localized: "uniconnect.accounts.remaining.minutes", defaultValue: "%lld min")
        return String.localizedStringWithFormat(format, Int64(mins))
    }

    /// «hace 12 s», «hace 4 min», «hace 3 h», «hace 2 d».
    func age(of date: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        let format: String
        let value: Int
        switch seconds {
        case ..<60:
            format = String(localized: "uniconnect.accounts.age.seconds", defaultValue: "hace %lld s")
            value = seconds
        case ..<3_600:
            format = String(localized: "uniconnect.accounts.age.minutes", defaultValue: "hace %lld min")
            value = seconds / 60
        case ..<86_400:
            format = String(localized: "uniconnect.accounts.age.hours", defaultValue: "hace %lld h")
            value = seconds / 3_600
        default:
            format = String(localized: "uniconnect.accounts.age.days", defaultValue: "hace %lld d")
            value = seconds / 86_400
        }
        return String.localizedStringWithFormat(format, Int64(value))
    }

    /// «sáb 15:00» in local time.
    static func weekdayTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_ES")
        formatter.setLocalizedDateFormatFromTemplate("EEE HH:mm")
        return formatter.string(from: date)
    }
}
