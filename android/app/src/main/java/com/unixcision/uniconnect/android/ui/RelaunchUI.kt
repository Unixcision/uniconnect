package com.unixcision.uniconnect.android.ui

import com.unixcision.uniconnect.android.domain.RelaunchOutcome
import com.unixcision.uniconnect.android.domain.RelaunchPreview
import com.unixcision.uniconnect.android.domain.RelaunchRequest

/**
 * Lo que la pantalla enseña de un relanzado o de «Actualizar Claude», de principio a fin.
 *
 * Las fases son estados distintos y no banderas sueltas: preparar, preguntar, esperar y contar.
 * Mezclarlas es como se acaba enseñando «hecho» encima de algo que sigue cerrando agentes. Los dos
 * verbos y los tres alcances, también «todo», pasan por aquí: [request] dice cuál.
 */
sealed interface RelaunchUI {
    val request: RelaunchRequest

    /** Pidiendo los planes. Nada se ha tocado todavía, así que se puede cancelar. */
    data class Planning(override val request: RelaunchRequest) : RelaunchUI

    /**
     * Enseña lo que va a pasar y espera un sí.
     *
     * Aparece a partir de [com.unixcision.uniconnect.android.domain.RelaunchConfirmation.THRESHOLD]
     * objetivos, siempre con «Actualizar Claude» o «todo», y siempre que vaya a escribir a alguna IA.
     *
     * @property replanning se está pidiendo otro plan con las opciones de [request]; [preview] es el
     *   anterior y no se puede confirmar hasta que llegue el nuevo.
     */
    data class Confirm(override val request: RelaunchRequest, val preview: RelaunchPreview, val replanning: Boolean = false) : RelaunchUI

    /** En marcha. Los equipos ya lo aceptaron; esto solo espera noticias. */
    data class Running(override val request: RelaunchRequest, val total: Int) : RelaunchUI

    /**
     * Terminado, con el detalle de cada ventana y de cada equipo.
     *
     * Se enseña aunque haya ido bien: después de reiniciar veintiséis agentes, «no ha pasado nada
     * malo» no es lo mismo que saber que volvieron los veintiséis.
     */
    data class Done(override val request: RelaunchRequest, val outcome: RelaunchOutcome) : RelaunchUI

    /** No se pudo ni empezar. */
    data class Failed(override val request: RelaunchRequest, val message: Int) : RelaunchUI
}
