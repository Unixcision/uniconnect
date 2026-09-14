package com.unixcision.uniconnect.android.domain

/**
 * Si una petición de relanzado se ejecuta directa o se enseña antes.
 *
 * Desde un móvil, «todo el sistema» está a un toque sin querer de veintiséis agentes reiniciados.
 * Una ventana suelta no: el que la pulsa está mirándola.
 */
object RelaunchConfirmation {
    /** A partir de cuántos objetivos se pregunta antes. */
    const val THRESHOLD = 5

    /**
     * Whether a plan of [targetCount] targets should be shown before it runs.
     *
     * Se cuenta por objetivos y no por alcance a propósito: un espacio de trabajo con una sola
     * ventana no merece una pregunta, y una máquina con veinte sí, aunque el botón sea el mismo.
     */
    fun needsConfirmation(targetCount: Int): Boolean = targetCount >= THRESHOLD
}
