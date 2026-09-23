package com.unixcision.uniconnect.android.domain

/**
 * Un archivo de la bandeja de entrada del equipo (`inbox.v1`).
 *
 * [path] es relativo a la bandeja y es lo que se pide para leer o borrar; [absolute] es la ruta
 * del equipo, la que se pega en el compositor para que la IA la abra.
 */
data class InboxEntry(
    val path: String,
    val absolute: String,
    val name: String,
    val size: Long,
    /** Segundos desde época, hora del equipo. */
    val modified: Long,
    val kind: InboxKind,
)
