package com.unixcision.uniconnect.android.domain

/**
 * El nombre de un límite (§4.1): «5 horas», «Semana», «Semana · Opus»… La frase la pone la pantalla.
 */
sealed interface LimitName {
    data object FiveHours : LimitName
    data object Week : LimitName
    data object WeekOpus : LimitName
    data object WeekSonnet : LimitName
    data object WeekFable : LimitName

    /** Una ventana de otra duración, en horas: «N h». */
    data class Hours(val hours: Int) : LimitName

    /** Ni nombre conocido ni ventana: el id tal cual. */
    data class Raw(val id: String) : LimitName

    companion object {
        /** Claude por su id; Codex (y lo que no se conozca) por su ventana. */
        fun of(id: String, windowMinutes: Int?): LimitName = when (id) {
            "five_hour" -> FiveHours
            "seven_day" -> Week
            "seven_day_opus" -> WeekOpus
            "seven_day_sonnet" -> WeekSonnet
            "seven_day_fable" -> WeekFable
            else -> when {
                windowMinutes == 300 -> FiveHours
                windowMinutes == 10_080 -> Week
                windowMinutes != null && windowMinutes > 0 -> Hours(maxOf(1, windowMinutes / 60))
                else -> Raw(id)
            }
        }
    }
}
