package com.unixcision.uniconnect.android.ui

import com.unixcision.uniconnect.android.domain.RelaunchOperation
import com.unixcision.uniconnect.android.domain.RelaunchPlan

/**
 * Lo que la pantalla enseña de un relanzado, de principio a fin.
 *
 * Las tres fases son estados distintos y no banderas sueltas: preguntar, esperar y contar. Mezclarlas
 * es como se acaba enseñando «hecho» encima de algo que sigue cerrando agentes.
 */
sealed interface RelaunchUI {
    val machineID: String

    /**
     * Enseña lo que va a pasar y espera un sí.
     *
     * Solo aparece a partir de [com.unixcision.uniconnect.android.domain.RelaunchConfirmation.THRESHOLD]
     * objetivos. Desde un móvil, «todo el equipo» está a un toque sin querer de veintiséis agentes
     * reiniciados; una ventana suelta no, porque quien la pulsa la está mirando.
     */
    data class Confirm(override val machineID: String, val plan: RelaunchPlan) : RelaunchUI

    /** En marcha. El equipo ya lo aceptó; esto solo espera noticias. */
    data class Running(override val machineID: String, val operationID: String, val total: Int) : RelaunchUI

    /**
     * Terminado, con el detalle de cada ventana.
     *
     * Se enseña aunque haya ido bien: después de reiniciar veintiséis agentes, «no ha pasado nada
     * malo» no es lo mismo que saber que volvieron los veintiséis.
     */
    data class Done(override val machineID: String, val operation: RelaunchOperation) : RelaunchUI

    /** No se pudo ni empezar. */
    data class Failed(override val machineID: String, val message: Int) : RelaunchUI
}
