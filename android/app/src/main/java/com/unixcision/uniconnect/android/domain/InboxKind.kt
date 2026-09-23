package com.unixcision.uniconnect.android.domain

/** Tipo de un archivo de la bandeja, para elegir su vista previa. Lo decide el equipo por extensión. */
enum class InboxKind {
    IMAGE, VIDEO, AUDIO, DOCUMENT, OTHER;

    /** Lo que se puede reproducir o mirar dentro del móvil sin otra app. */
    val previewable: Boolean get() = this == IMAGE || this == VIDEO || this == AUDIO

    companion object {
        /** El valor del contrato (`image`, `video`…); lo desconocido cae en [OTHER], nunca rompe. */
        fun fromWire(raw: String?): InboxKind = entries.firstOrNull { it.name.equals(raw, ignoreCase = true) } ?: OTHER
    }
}
