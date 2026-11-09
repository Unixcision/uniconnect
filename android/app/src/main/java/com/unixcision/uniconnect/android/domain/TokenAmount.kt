package com.unixcision.uniconnect.android.domain

/**
 * Una cantidad de tokens redondeada para leerla de un vistazo: «412 mil», «1,2 M».
 *
 * [number] ya va con coma decimal; la palabra de la escala la pone la pantalla.
 */
data class TokenAmount(val number: String, val scale: Scale) {
    enum class Scale { UNITS, THOUSANDS, MILLIONS }

    companion object {
        /** Redondea [tokens] a la escala que se lee mejor: unidades, miles enteros o millones con un decimal. */
        fun of(tokens: Long): TokenAmount {
            require(tokens >= 0)
            if (tokens < 1_000) return TokenAmount(tokens.toString(), Scale.UNITS)
            val thousands = (tokens + 500) / 1_000
            if (thousands < 1_000) return TokenAmount(thousands.toString(), Scale.THOUSANDS)
            val tenths = (tokens + 50_000) / 100_000
            val whole = tenths / 10
            val decimal = tenths % 10
            return TokenAmount(if (decimal == 0L) "$whole" else "$whole,$decimal", Scale.MILLIONS)
        }
    }
}
