package com.unixcision.uniconnect.android.domain

/**
 * Lo que el equipo sabe de una ventana: dónde vive, qué tmux la sostiene y qué IA corre dentro.
 *
 * Es la respuesta de `mobile.terminal.details` (`contracts/window-details-v1`). Todo lo que el
 * contrato manda como `null` llega aquí como `null`: una ventana sin tmux, sin IA o con la IA sin
 * identificar se enseña tal cual, sin inventar nada. Los valores de texto se guardan **crudos**
 * (como `RelaunchReason`): un origen o un estado que esta versión no conoce se sigue viendo, en vez
 * de desaparecer.
 */
data class WindowDetails(
    val workspaceID: String,
    val windowID: String,
    /** Cuándo armó el equipo la respuesta, en ISO 8601 UTC. */
    val checkedAt: String?,
    val workspaceName: String,
    /** `local` o `ssh`. */
    val workspaceKind: String,
    /** Destino SSH efectivo; nulo en local y con la bóveda cerrada. */
    val host: DetailsHost?,
    /** `usuario@host:puerto` tal cual lo manda el equipo; nulo en local. */
    val hostLabel: String?,
    val windowName: String,
    /** Nulo en una ventana antigua sin tmux (`reason = sin_tmux`). */
    val tmux: DetailsTmux?,
    /** Nulo si no hay IA ni guardada ni en vivo. */
    val agent: DetailsAgent?,
    /** `sin_ia`, `identidad_ambigua`, `sin_id`, `host_inaccesible`, `sin_tmux` o nulo. */
    val reason: String?,
) {
    val isSSH: Boolean get() = workspaceKind == "ssh"

    /** La interpretación del motivo, cuando esta versión la tiene. */
    val reasonKind: DetailsReason? get() = DetailsReason.named(reason)

    /** Cómo se nombra el VPS: la etiqueta del equipo o, si no vino, la que se deduce del destino. */
    val hostDescription: String? get() = hostLabel ?: host?.label
}

/** Un destino SSH: usuario, máquina y puerto. Nunca lleva contraseñas ni la orden de conexión. */
data class DetailsHost(val user: String?, val hostname: String, val port: Int?) {
    val label: String get() = buildString {
        user?.let { append(it).append('@') }
        append(hostname)
        port?.let { append(':').append(it) }
    }
}

/**
 * El tmux de la ventana.
 *
 * [socket] y [session] son la identidad durable; [sessionID] (`$N`) y [paneID] (`%N`) solo existen
 * mientras la sesión está en marcha, porque tmux los renumera al reiniciar su servidor.
 */
data class DetailsTmux(
    val socket: String,
    val session: String,
    val sessionID: String?,
    val paneID: String?,
    val live: Boolean,
) {
    /** `default` es el servidor tmux por defecto, el de `tmux` a secas. */
    val isDefaultServer: Boolean get() = socket == "default"
}

/** La IA de la ventana, confirmada ahora o tal como quedó guardada. */
data class DetailsAgent(
    /** `claude`, `codex`, `agy`, `grok` u otro id del catálogo. */
    val provider: String,
    /** El nombre que pone el equipo, como «Claude Code». */
    val displayName: String?,
    /** Nulo si se vio la IA pero todavía no su conversación (`reason = sin_id`). */
    val sessionID: String?,
    val cwd: String?,
    val asRoot: Boolean?,
    /** `ficha`, `rollout`, `argv`, `hook`, `manifiesto` o `registro`. */
    val source: String?,
    /** `activo`, `guardado` o `interrumpido`. */
    val state: String?,
    val observedAt: String?,
    /** La orden para reanudarla. Nula si no hay conversación que reanudar. */
    val resume: DetailsResume?,
) {
    /** Lo que se enseña como nombre: el del equipo o, si no vino, el identificador. */
    val name: String get() = displayName?.takeIf { it.isNotBlank() } ?: provider

    val stateKind: DetailsAgentState? get() = DetailsAgentState.named(state)

    val sourceKind: DetailsSource? get() = DetailsSource.named(source)
}

/**
 * Cómo reanudar la conversación, siempre sin preguntas.
 *
 * Se deriva en el equipo y nunca se guarda en ningún sitio. [command] es la orden de shell entera
 * (`cd -- '<carpeta>' && …`), lista para copiar.
 */
data class DetailsResume(
    val argv: List<String>,
    val environment: Map<String, String>,
    val command: String,
    /** Falso cuando esa IA no tiene un modo sin preguntas comprobado (hoy, grok). */
    val noPromptVerified: Boolean,
)

/** Estado de la IA en la respuesta. */
enum class DetailsAgentState(val wire: String) {
    /** Confirmada en esta lectura. */
    ACTIVE("activo"),

    /** Lo último que se guardó, sin comprobar ahora. */
    SAVED("guardado"),

    /** Estaba activa cuando cayó el tmux: se reanudará al abrir. */
    INTERRUPTED("interrumpido");

    companion object {
        fun named(raw: String?): DetailsAgentState? = entries.firstOrNull { it.wire == raw }
    }
}

/** De dónde sale el identificador de la conversación. */
enum class DetailsSource(val wire: String) {
    /** `~/.claude/sessions/<pid>.json`: la fuente fiable de Claude. */
    SESSION_FILE("ficha"),

    /** El rollout que Codex tiene abierto. */
    ROLLOUT("rollout"),

    /** La línea de órdenes: puede estar desfasada tras `/clear` o `/resume`. */
    ARGV("argv"),

    /** Aviso del propio agente. */
    HOOK("hook"),

    /** El supervisor del servidor (`recovery.py`). */
    MANIFEST("manifiesto"),

    /** Solo lo guardado en UniConnect, sin confirmar ahora. */
    RECORD("registro");

    companion object {
        fun named(raw: String?): DetailsSource? = entries.firstOrNull { it.wire == raw }
    }
}

/** Por qué falta algo en la respuesta. */
enum class DetailsReason(val wire: String) {
    NO_AGENT("sin_ia"),
    AMBIGUOUS("identidad_ambigua"),
    NO_ID("sin_id"),
    HOST_UNREACHABLE("host_inaccesible"),
    NO_TMUX("sin_tmux");

    companion object {
        fun named(raw: String?): DetailsReason? = entries.firstOrNull { it.wire == raw }
    }
}
