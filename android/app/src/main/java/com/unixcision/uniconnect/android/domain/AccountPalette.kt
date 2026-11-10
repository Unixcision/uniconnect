package com.unixcision.uniconnect.android.domain

import java.util.Locale

/**
 * El color de cada cuenta, el mismo en Mac, Linux y Android (`contracts/accounts-v1/paleta.json`).
 *
 * El índice es FNV-1a de 32 bits sobre los bytes UTF-8 del email en minúsculas, módulo el número de
 * colores. Sin email (sin sesión, no legible, clave de API…) se usa [NEUTRAL].
 */
object AccountPalette {
    /** Los colores, en ARGB, en el orden del contrato. */
    val COLORS: List<Long> = listOf(
        0xFFEB5757, 0xFFF2994A, 0xFF27AE60, 0xFF2F80ED, 0xFF9B51E0, 0xFF00A3A3, 0xFFC9A227, 0xFFE05BA8,
    )

    /** El color de lo que no tiene email. */
    const val NEUTRAL: Long = 0xFF8E8E93

    /** 0x811c9dc5 como Int con signo: los mismos 32 bits. */
    private const val OFFSET_BASIS: Int = -2128831035
    private const val PRIME = 0x01000193

    /** El índice en [COLORS] de [email]: el mismo email, con cualquier mayúscula, da el mismo color. */
    fun indexOf(email: String): Int {
        var hash = OFFSET_BASIS
        for (byte in email.lowercase(Locale.ROOT).toByteArray(Charsets.UTF_8)) {
            // La multiplicación de Int ya es módulo 2^32: es exactamente la de FNV-1a.
            hash = (hash xor (byte.toInt() and 0xff)) * PRIME
        }
        return (hash.toUInt() % COLORS.size.toUInt()).toInt()
    }

    /** El color ARGB de [email], o [NEUTRAL] sin email. */
    fun colorOf(email: String?): Long = email?.takeIf { it.isNotBlank() }?.let { COLORS[indexOf(it)] } ?: NEUTRAL
}
