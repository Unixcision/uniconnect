package com.unixcision.uniconnect.android.ui

import com.unixcision.uniconnect.android.domain.WindowDetails

/**
 * Lo que enseña el diálogo «Detalles» de una ventana: esperando, con la respuesta o sin ella.
 *
 * Son estados distintos, no banderas sueltas, por lo mismo que en ``RelaunchUI``: mezclar «se está
 * comprobando» con «esto es lo que hay» es como se acaba enseñando un dato viejo como si fuera de
 * ahora.
 */
sealed interface WindowDetailsUI {
    /** Pedido al equipo; todavía no ha contestado. */
    data class Loading(val machineID: String, val workspaceID: String, val windowID: String) : WindowDetailsUI

    /** La respuesta del equipo. [copied] dice que la orden para reanudar ya está en el portapapeles. */
    data class Ready(val details: WindowDetails, val copied: Boolean = false) : WindowDetailsUI

    /**
     * No llegó respuesta.
     *
     * [message] es un recurso de texto; [detail], el mensaje en español que mandó el equipo si lo
     * rechazó (por ejemplo «UniConnect está bloqueado.»), que se enseña tal cual.
     */
    data class Failed(val message: Int, val detail: String? = null) : WindowDetailsUI
}
