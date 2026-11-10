package com.unixcision.uniconnect.android.domain

import java.util.Locale
import kotlin.math.roundToLong

/**
 * Cómo se escriben los números de «Uso por cuenta», con coma decimal como en el Mac: el ritmo
 * («113,7») y los porcentajes («51 %», «3,5 %»).
 */
object UsageNumbers {
    private val SPANISH: Locale = Locale.forLanguageTag("es-ES")

    /** Un decimal, con coma: «113,7», «17,5», «0,0». */
    fun oneDecimal(value: Double): String = String.format(SPANISH, "%.1f", value)

    /** El porcentaje redondeado a una décima, sin «,0»: «51 %», «3,5 %». */
    fun percent(value: Double): String {
        val rounded = (value * 10).roundToLong() / 10.0
        return if (rounded % 1.0 == 0.0) "${rounded.toLong()} %" else "${oneDecimal(rounded)} %"
    }
}
