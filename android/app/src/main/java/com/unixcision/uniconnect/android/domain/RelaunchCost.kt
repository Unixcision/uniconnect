package com.unixcision.uniconnect.android.domain

/**
 * Lo que costará avisar a las IA tras reabrirlas, para enseñarlo antes de confirmar.
 *
 * Reabrir no gasta cupo; lo que gasta es el mensaje, porque obliga a releer la conversación entera
 * (el 09-11-2026 se comió el 37 % del cupo de Fable). El equipo dice por objetivo si le escribirá
 * (`message`) y suma en `estimated_tokens` lo que releerán las que sí.
 */
sealed interface RelaunchCost {
    /** Ningún equipo lo dice (anteriores al 09-11-2026): no se inventa una cifra. */
    data object Unknown : RelaunchCost

    /** No hace falta escribir a ninguna. */
    data object Free : RelaunchCost

    /**
     * Se escribirá a [messaged] IA, que releerán unos [tokens], o nulo si no se sabe cuántos.
     *
     * [partial]: a alguna le falta su cifra, o algún equipo no la da, así que [tokens] es un mínimo.
     */
    data class Rereads(val messaged: Int, val tokens: Long?, val partial: Boolean) : RelaunchCost

    companion object {
        /**
         * El coste de ejecutar [plans] juntos. Solo cuentan los que se pueden ejecutar: un plan
         * bloqueado no va a escribir a nadie.
         */
        fun of(plans: List<RelaunchPlan>): RelaunchCost {
            val runnable = plans.filter { it.actionable }
            val known = runnable.filter { plan -> plan.estimatedTokens != null || plan.targets.any { it.message != null } }
            if (known.isEmpty()) return Unknown
            val messaged = known.flatMap { it.targets }.filter { it.message == true }
            val everyHostSays = known.size == runnable.size
            if (messaged.isEmpty()) return if (everyHostSays) Free else Unknown
            val tokens = known.sumOf { plan ->
                plan.estimatedTokens ?: plan.targets.filter { it.message == true }.sumOf { it.contextTokens ?: 0L }
            }
            val partial = !everyHostSays || messaged.any { it.contextTokens == null }
            return Rereads(messaged.size, tokens.takeIf { it > 0 }, partial)
        }
    }
}
