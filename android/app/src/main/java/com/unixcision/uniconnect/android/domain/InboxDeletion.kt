package com.unixcision.uniconnect.android.domain

/**
 * Qué borrar de la bandeja. Los criterios se SUMAN: «anteriores a 30 días» y «mayores de 50 MB»
 * borra solo lo que cumple las dos cosas. [everything] lo borra todo; [paths] borra esas rutas.
 *
 * Sin ningún criterio el equipo no borra nada: es a propósito, un filtro vacío no puede ser «todo».
 */
data class InboxDeletion(
    val everything: Boolean = false,
    val olderThanDays: Int? = null,
    val largerThanBytes: Long? = null,
    val paths: List<String>? = null,
    /** Solo calcula: cuántos y cuánto se liberaría, sin tocar nada. */
    val dryRun: Boolean = false,
) {
    /** Hay al menos un criterio: si no, el botón de borrar no se ofrece. */
    val hasCriterion: Boolean get() = everything || olderThanDays != null || largerThanBytes != null || !paths.isNullOrEmpty()
}

/** Lo que se borró (o se borraría) y lo que queda. */
data class InboxDeletionResult(
    val dryRun: Boolean,
    val deleted: Int,
    val freedBytes: Long,
    val remainingCount: Int,
    val remainingBytes: Long,
)
