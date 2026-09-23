package com.unixcision.uniconnect.android.domain

/**
 * Qué se trae solo para la miniatura y qué espera a que se toque.
 *
 * Una foto del móvil pesa 2–6 MB: traer las de la primera página es barato y es lo que hace
 * que la galería se entienda de un vistazo. Un vídeo, un audio o una imagen enorme no se bajan
 * por verlos pasar en la lista; se bajan cuando se abren.
 */
object InboxPreviewRule {
    /** Por encima de esto, ni una imagen se baja sola. */
    const val AUTO_THUMBNAIL_BYTES = 12L * 1024 * 1024

    fun thumbnailOnSight(entry: InboxEntry): Boolean = entry.kind == InboxKind.IMAGE && entry.size in 1..AUTO_THUMBNAIL_BYTES
}
