package com.unixcision.uniconnect.android.domain

/**
 * Los planes de una petición, uno por equipo, tal y como se enseñan en un solo diálogo.
 *
 * Con un solo equipo manda [RelaunchPresentation.decide], como siempre. Con varios («todo») no se
 * ejecuta nunca sin preguntar: es el gesto con más en juego de la app.
 */
data class RelaunchPreview(val request: RelaunchRequest, val hosts: List<RelaunchHostPlan>) {
    /** Qué hacer con esta previsualización. */
    enum class Step {
        /** No se pudo pedir ni un plan, y no hay nada más que contar. */
        FAILED,

        /** No hay nada que hacer ni que contar. */
        NOTHING,

        /** Hay algo que contar y nada que ejecutar. */
        SHOW,

        /** Hay algo que ejecutar y se pregunta antes. */
        CONFIRM,

        /** Adelante sin preguntar. */
        APPLY,
    }

    /** Los planes que llegaron. */
    val plans: List<RelaunchPlan> get() = hosts.mapNotNull { it.plan }

    /** Los equipos con algo que ejecutar: los únicos a los que se les manda `apply`. */
    val runnable: List<RelaunchHostPlan> get() = hosts.filter { it.plan?.actionable == true }

    /** Los equipos de los que no llegó plan. */
    val failed: List<RelaunchHostPlan> get() = hosts.filter { it.plan == null }

    /** Si hay algo que ejecutar en algún equipo. */
    val actionable: Boolean get() = runnable.isNotEmpty()

    /** Cuántas ventanas se tocarían, sumando los equipos que se pueden ejecutar. */
    val targetCount: Int get() = runnable.sumOf { it.plan?.targets?.size ?: 0 }

    /** Lo que gastaría avisar a las IA tras reabrirlas. */
    val cost: RelaunchCost get() = RelaunchCost.of(plans)

    val step: Step get() {
        val plans = plans
        if (plans.isEmpty()) return if (hosts.size > 1) Step.SHOW else Step.FAILED
        if (hosts.size == 1) {
            return when (RelaunchPresentation.decide(plans.single())) {
                is RelaunchDecision.Nothing -> Step.NOTHING
                is RelaunchDecision.Show -> Step.SHOW
                is RelaunchDecision.Confirm -> Step.CONFIRM
                is RelaunchDecision.Apply -> if (request.everywhere) Step.CONFIRM else Step.APPLY
            }
        }
        if (actionable) return Step.CONFIRM
        val somethingToTell = failed.isNotEmpty() ||
            plans.any { it.targets.isNotEmpty() || it.exclusions.isNotEmpty() || it.unavailableReason != null }
        return if (somethingToTell) Step.SHOW else Step.NOTHING
    }
}
