package com.unixcision.uniconnect.android.domain

/**
 * Lo que «Actualizar Claude» puede cambiar al reabrir (`agent.update`): el modelo y el effort.
 *
 * Un campo nulo es «igual que estaba» y no viaja: el equipo conserva el de la conversación. Con
 * `agent.relaunch` no se mandan nunca, porque el equipo contestaría `opciones_no_validas`: relanzar
 * no cambia nada.
 */
data class RelaunchOptions(val model: String? = null, val effort: String? = null) {
    /** Nada que cambiar: no viaja `options`. */
    val isEmpty: Boolean get() = model == null && effort == null

    /** Si el equipo las aceptaría: un alias o id de Claude con la forma del contrato y un effort conocido. */
    val isValid: Boolean get() = (model == null || MODEL_PATTERN.matches(model)) && (effort == null || effort in EFFORTS)

    companion object {
        private val MODEL_PATTERN = Regex("^[a-z0-9.\\-\\[\\]]{2,40}$")

        /** Los modelos que ofrece el selector, como alias de Claude (los nombres los pone la pantalla). */
        val MODELS: List<String> = listOf("fable[1m]", "opus[1m]", "sonnet[1m]", "haiku")

        /** Los efforts que acepta el contrato, de menos a más. */
        val EFFORTS: List<String> = listOf("low", "medium", "high", "xhigh", "max")
    }
}
