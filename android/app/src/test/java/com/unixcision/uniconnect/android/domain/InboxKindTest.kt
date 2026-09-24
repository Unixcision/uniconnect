package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Test

/** El tipo decide la vista previa: lo del equipo llega por nombre de contrato, lo del móvil por MIME. */
class InboxKindTest {
    @Test
    fun loDelContratoSeLeeYLoDesconocidoNoRompe() {
        assertEquals(listOf(InboxKind.IMAGE, InboxKind.VIDEO, InboxKind.OTHER, InboxKind.OTHER),
            listOf("image", "VIDEO", "holograma", null).map(InboxKind::fromWire))
    }

    @Test
    fun loDelMovilSeReconocePorSuMime() {
        assertEquals(
            listOf(InboxKind.IMAGE, InboxKind.VIDEO, InboxKind.AUDIO, InboxKind.DOCUMENT, InboxKind.DOCUMENT, InboxKind.OTHER, InboxKind.OTHER),
            listOf("image/png", "video/mp4", "audio/ogg", "application/pdf",
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "application/octet-stream", null)
                .map(InboxKind::fromMime),
        )
    }
}
