package com.unixcision.uniconnect.android.domain

import kotlin.math.roundToInt

/**
 * Sizes as a reader reads them, in the units a phone's own settings use.
 *
 * Powers of 1024 with one decimal below 100, none above, because "181 MB" is a size and
 * "180,6 MB" is a measurement nobody asked for.
 */
object ByteSize {
    /** [bytes] as a short string such as `57 MB`, `1,4 GB` or `812 kB`. */
    fun format(bytes: Long): String {
        if (bytes < 1024) return "$bytes B"
        val units = listOf("kB", "MB", "GB")
        var value = bytes.toDouble() / 1024
        var unit = 0
        while (value >= 1024 && unit < units.lastIndex) {
            value /= 1024
            unit++
        }
        val text = if (value < 100) {
            val tenths = (value * 10).roundToInt()
            if (tenths % 10 == 0) "${tenths / 10}" else "${tenths / 10},${tenths % 10}"
        } else value.roundToInt().toString()
        return "$text ${units[unit]}"
    }

    /** How far along a download reads, as a whole percentage. */
    fun percent(done: Long, total: Long): Int = if (total <= 0) 0 else ((done.toDouble() / total) * 100).toInt().coerceIn(0, 100)
}
