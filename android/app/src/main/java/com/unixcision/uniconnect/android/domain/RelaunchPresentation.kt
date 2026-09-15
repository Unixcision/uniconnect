package com.unixcision.uniconnect.android.domain

/**
 * Qué hacer con un plan recién pedido: enseñarlo, preguntar, ejecutarlo o decir que no había nada.
 *
 * Existe porque esa decisión vivía repartida en el ViewModel y se equivocaba en el caso que más
 * importa. Un plan con cero objetivos pasaba por `needsConfirmation(0)`, que con umbral 5 devuelve
 * `false`, y se iba **directo a `apply`**: la pantalla que explica por qué no se puede relanzar
 * nunca llegaba a verse, y la operación vacía terminaba como «Relanzadas 0 de 0».
 */
sealed interface RelaunchDecision {
    /** No había nada que hacer y tampoco nada que contar. */
    data object Nothing : RelaunchDecision

    /** Hay algo que contar y nada que ejecutar: el motivo, las exclusiones, o ambos. */
    data class Show(val plan: RelaunchPlan) : RelaunchDecision

    /** Hay bastante en juego como para preguntar antes. */
    data class Confirm(val plan: RelaunchPlan) : RelaunchDecision

    /** Adelante sin preguntar. */
    data class Apply(val plan: RelaunchPlan) : RelaunchDecision
}

/** Cómo se presenta un plan de relanzado. */
object RelaunchPresentation {
    /**
     * Decide qué hacer con `plan`.
     *
     * Tres reglas, y las tres nacen de un fallo real:
     * - **Nunca se ejecuta un plan sin objetivos.** Ni siquiera «por si acaso»: no hay nada que
     *   relanzar y la llamada solo sirve para acabar enseñando un recuento de cero.
     * - **Un plan sin objetivos pero con algo que contar se enseña.** El motivo global lo manda un
     *   equipo que sabe que no puede relanzar; las exclusiones las manda uno que excluyó sus
     *   candidatos uno a uno y no tiene motivo global que dar (es lo que hace hoy el equipo Linux).
     *   Los dos casos tienen causas que el usuario necesita ver, y tratarlos como «no había nada»
     *   las esconde.
     * - **«No había nada» se reserva para cuando de verdad no hay nada**: sin objetivos, sin
     *   exclusiones y sin motivo.
     */
    fun decide(plan: RelaunchPlan): RelaunchDecision = when {
        plan.targets.isEmpty() && plan.exclusions.isEmpty() && plan.unavailableReason == null ->
            RelaunchDecision.Nothing
        plan.targets.isEmpty() || plan.unavailableReason != null -> RelaunchDecision.Show(plan)
        RelaunchConfirmation.needsConfirmation(plan.targets.size) -> RelaunchDecision.Confirm(plan)
        else -> RelaunchDecision.Apply(plan)
    }
}
