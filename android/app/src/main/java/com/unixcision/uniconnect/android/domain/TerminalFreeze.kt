package com.unixcision.uniconnect.android.domain

/**
 * El texto del terminal congelado en un instante, para seleccionarlo con calma.
 *
 * La pantalla sigue viva mientras la IA escribe; si la selección leyera de ella, cada refresco
 * cambiaría el texto bajo el dedo y se perdería lo marcado. Aquí la foto se saca al abrir y solo
 * se repite cuando se pide con [take]. Si en ese momento no hay pantalla que leer, se queda la
 * foto anterior: mejor texto de hace un momento que una hoja vacía.
 */
class TerminalFreeze(private val capture: () -> TerminalSnapshot?, private val clock: () -> Long) {
    /** Lo que se congeló y cuándo (milisegundos de [clock]). */
    data class Photo(val text: String, val takenAt: Long)

    var photo: Photo? = null
        private set

    /** Saca otra foto de lo que hay ahora en pantalla y la devuelve. */
    fun take(): Photo? {
        val snapshot = capture() ?: return photo
        return Photo(TerminalText.of(snapshot), clock()).also { photo = it }
    }
}
