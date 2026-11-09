package com.unixcision.uniconnect.android.domain

/**
 * Cómo fue `claude update` en una instalación (`updates[]` de `agent.update`).
 *
 * Una instalación es equipo destino, usuario y binario: corre una sola vez por cada una y antes de
 * cerrar nada de ella. [state] se guarda crudo para que un valor nuevo del contrato se enseñe en
 * vez de perderse; [kind] es su lectura.
 */
data class RelaunchUpdate(val host: String, val state: String, val from: String? = null, val to: String? = null) {
    /** Lo que esta versión entiende de [state]. */
    enum class Kind { UPDATED, UP_TO_DATE, FAILED, UNKNOWN }

    val kind: Kind get() = when (state) {
        "actualizado" -> Kind.UPDATED
        "ya_al_dia" -> Kind.UP_TO_DATE
        "fallida" -> Kind.FAILED
        else -> Kind.UNKNOWN
    }
}
