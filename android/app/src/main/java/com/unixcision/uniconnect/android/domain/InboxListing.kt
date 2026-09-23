package com.unixcision.uniconnect.android.domain

/** Una página de la bandeja, con el total de la carpeta entera: lo que mide el ajuste de Adjuntos. */
data class InboxListing(
    val count: Int,
    val totalBytes: Long,
    val oldest: Long?,
    val newest: Long?,
    val entries: List<InboxEntry>,
)
