package com.unixcision.uniconnect.android.domain

/**
 * Lo que una petición de relanzado hace, y a cuánto alcanza.
 *
 * Tres verbos y nunca uno: quien ve una ventana en blanco casi siempre quiere el transporte de
 * vuelta, no su conversación cerrada y reabierta. Juntarlos es lo que convierte una reconexión en
 * trabajo perdido, así que la diferencia vive en el tipo y no en una bandera.
 */
enum class RelaunchVerb(val wire: String) {
    /** Reengancha con lo que ya corre. No cierra nada, no crea nada. */
    RECONNECT("transport.reconnect"),

    /** Cierra el agente y lo reabre sobre la misma conversación. Nunca toca tmux. */
    RELAUNCH("agent.relaunch"),

    /** Le dice a un agente vivo que retome el encargo anterior. No es un visto bueno en blanco. */
    CONTINUE("agent.continue"),
}

/**
 * Hasta dónde llega una petición.
 *
 * No existe un alcance «todo el sistema»: lo compone este cliente pidiendo [Machine] a cada equipo.
 * Así un equipo que no contesta se ve como un equipo que no contesta, en vez de desaparecer dentro
 * del total de otro.
 */
sealed interface RelaunchScope {
    data class Window(val machineID: String, val workspaceID: String, val windowID: String) : RelaunchScope
    data class Workspace(val machineID: String, val workspaceID: String) : RelaunchScope
    data class Machine(val machineID: String) : RelaunchScope
}

/** En qué anda cada objetivo. Se informa por objetivo, nunca en un total. */
enum class RelaunchTargetState(val wire: String) {
    PLANNED("planificado"),
    CLOSING("cerrando"),
    REOPENING("reabriendo"),
    REATTACHING("reenganchando"),
    DELIVERING("entregando"),
    VERIFIED("verificado"),
    NEEDS_USER("necesita_usuario"),
    SKIPPED("omitido"),
    FAILED("fallido");

    /** Sin fases por delante: ya no va a cambiar solo. */
    val settled: Boolean get() = this == VERIFIED || this == NEEDS_USER || this == SKIPPED || this == FAILED

    companion object {
        fun named(raw: String?): RelaunchTargetState = entries.firstOrNull { it.wire == raw } ?: FAILED
    }
}

/**
 * Por qué un objetivo se quedó fuera, espera a una persona o falló.
 *
 * El identificador viaja; la frase la pone esta app. Una causa en un objetivo **no** es un error de
 * la llamada: veinticinco pueden salir bien mientras uno espera a que alguien conteste.
 */
enum class RelaunchCause(val wire: String) {
    AMBIGUOUS_IDENTITY("identidad_ambigua"),
    UNKNOWN_DIALOG("dialogo_desconocido"),
    FOLDER_TRUST("confianza_carpeta"),
    PERMISSIONS("permisos"),
    NO_AUTHORITY("sin_autoridad"),

    /** Aceptado y cancelado antes de mandarle nada. No se tocó: no es lo mismo que haber fallado. */
    NOT_SENT("no_enviado"),
    GENERATION_CHANGED("generacion_cambiada"),
    HOST_UNREACHABLE("host_inaccesible"),
    DUPLICATE("duplicado"),
    UNSUPPORTED("no_soportado");

    companion object {
        fun named(raw: String?): RelaunchCause? = entries.firstOrNull { it.wire == raw }
    }
}

/** Un objetivo tal y como lo enseña la previsualización. */
data class RelaunchTarget(val key: String, val label: String, val provider: String)

/** Un objetivo que el plan deja fuera, con su motivo. Nunca en silencio. */
data class RelaunchExclusion(val label: String, val cause: RelaunchCause?)

/**
 * Lo que un relanzado haría, antes de hacerlo.
 *
 * Existe para poder enseñar «esto toca 26 agentes» mientras todavía es una frase y no un hecho. En
 * un móvil, la diferencia entre las dos cosas es un toque sin querer.
 */
data class RelaunchPlan(
    val operationID: String,
    val token: String,
    val verb: RelaunchVerb,
    val targets: List<RelaunchTarget>,
    val exclusions: List<RelaunchExclusion>,
)

/** Cómo quedó un objetivo. */
data class RelaunchResult(
    val key: String,
    val state: RelaunchTargetState,
    val cause: RelaunchCause? = null,
    val effectiveID: String? = null,
)

/** Una operación aceptada y lo lejos que va. */
data class RelaunchOperation(
    val operationID: String,
    /**
     * Que la operación **ya existía**, no que haya terminado.
     *
     * Leer una cosa por la otra es como se acaba enseñando un tic verde al lado de un agente que
     * todavía se está cerrando. Quien dice si terminó es [finished].
     */
    val recovered: Boolean,
    val results: List<RelaunchResult>,
) {
    /** Termina cuando ningún objetivo tiene fases por delante. */
    val finished: Boolean get() = results.all { it.state.settled }

    /** Los que necesitan que una persona conteste algo. */
    val needingUser: List<RelaunchResult> get() = results.filter { it.state == RelaunchTargetState.NEEDS_USER }

    /** Solo lo fallido se reintenta: lo verificado no se vuelve a tocar y lo que espera a alguien no se arregla solo. */
    val retryable: List<RelaunchResult> get() = results.filter { it.state == RelaunchTargetState.FAILED }
}
