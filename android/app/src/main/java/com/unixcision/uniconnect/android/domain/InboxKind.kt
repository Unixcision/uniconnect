package com.unixcision.uniconnect.android.domain

/** Tipo de un archivo de la bandeja, para elegir su vista previa. Lo decide el equipo por extensión. */
enum class InboxKind {
    IMAGE, VIDEO, AUDIO, DOCUMENT, OTHER;

    /** Lo que se puede reproducir o mirar dentro del móvil sin otra app. */
    val previewable: Boolean get() = this == IMAGE || this == VIDEO || this == AUDIO

    companion object {
        /** El valor del contrato (`image`, `video`…); lo desconocido cae en [OTHER], nunca rompe. */
        fun fromWire(raw: String?): InboxKind = entries.firstOrNull { it.name.equals(raw, ignoreCase = true) } ?: OTHER

        /** El tipo de un archivo del propio móvil por su MIME (`image/png`, `video/mp4`…). */
        fun fromMime(mime: String?): InboxKind {
            val value = mime?.lowercase().orEmpty()
            return when {
                value.startsWith("image/") -> IMAGE
                value.startsWith("video/") -> VIDEO
                value.startsWith("audio/") -> AUDIO
                value.startsWith("text/") || value == "application/pdf" || value.contains("document") ||
                    value.contains("sheet") || value.contains("presentation") || value == "application/json" ||
                    value == "application/zip" || value == "application/msword" -> DOCUMENT
                else -> OTHER
            }
        }
    }
}
