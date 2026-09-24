package com.unixcision.uniconnect.android.domain

/** Cómo se pinta el valor de una fila. */
enum class DetailsLineKind {
    /** Texto normal. */
    TEXT,

    /** Un dato para copiar a mano (el id de la conversación, la carpeta): monoespaciado. */
    CODE,

    /** La orden para reanudar: monoespaciada, seleccionable y con «Copiar orden». */
    COMMAND,
}

/** Una fila del modal: su etiqueta y su valor, ya en texto. */
data class DetailsLine(val label: String, val value: String, val kind: DetailsLineKind = DetailsLineKind.TEXT)

/**
 * Lo que enseña el modal con una respuesta: el aviso de arriba, las filas y la nota de la orden.
 *
 * [notice] va encima de las filas (la comprobación en vivo falló); [commandNote], debajo de la orden
 * (la IA no tiene un modo sin preguntas verificado).
 */
data class DetailsSheet(val notice: String?, val lines: List<DetailsLine>, val commandNote: String?)

/**
 * Las filas del modal «Detalles» a partir de una respuesta de `mobile.terminal.details`.
 *
 * Es la tabla de `contracts/window-details-v1/LEEME.md` tal cual, y `filas.json` trae lo que tiene
 * que salir para cada respuesta de ejemplo: el mismo texto que el Mac y Linux, letra por letra.
 * Vive aquí, sin Compose ni `Resources`, para poder probarlo en la JVM: quien pinta pasa [text], que
 * resuelve cada [DetailsText] con `strings.xml`.
 */
object WindowDetailsRows {
    /**
     * Las filas de [details], en el orden del contrato.
     *
     * - Las de la IA (estado, conversación, carpeta, root, origen y orden) solo salen si hay `agent`.
     * - «Como root» solo en SSH. «Orden para reanudarla» solo si hay `resume`.
     * - Un valor vacío o `null` sale como [DetailsText.EMPTY]; un estado o un origen que esta
     *   versión no conoce, tal cual llega.
     */
    fun render(details: WindowDetails, text: (DetailsText) -> String): DetailsSheet {
        val empty = text(DetailsText.EMPTY)
        fun shown(value: String?) = value?.takeIf { it.isNotEmpty() } ?: empty
        val reason = details.reasonKind
        val unreachable = reason == DetailsReason.HOST_UNREACHABLE
        val notice = when {
            !unreachable -> null
            details.isSSH -> text(DetailsText.UNREACHABLE_SSH)
            else -> text(DetailsText.UNREACHABLE_LOCAL)
        }
        val lines = mutableListOf<DetailsLine>()
        lines += DetailsLine(text(DetailsText.WORKSPACE), shown(details.workspaceName))
        lines += DetailsLine(
            text(DetailsText.KIND),
            when {
                !details.isSSH -> text(DetailsText.KIND_LOCAL)
                // La etiqueta la manda el equipo ya normalizada (`usuario@host:puerto`), también con
                // la bóveda cerrada; no se recompone aquí para no enseñar otra cosa que el escritorio.
                details.hostLabel != null -> text(DetailsText.KIND_SSH).format(details.hostLabel)
                else -> text(DetailsText.KIND_SSH_UNNAMED)
            },
        )
        lines += DetailsLine(text(DetailsText.WINDOW), shown(details.windowName))
        val tmux = details.tmux
        if (tmux == null) {
            // Las tres filas de tmux se quedan en una: una ventana antigua sin sesión recuperable.
            lines += DetailsLine(text(DetailsText.TMUX_SESSION), text(DetailsText.TMUX_NONE))
        } else {
            lines += DetailsLine(text(DetailsText.TMUX_SOCKET), if (tmux.isDefaultServer) text(DetailsText.TMUX_DEFAULT) else shown(tmux.socket))
            lines += DetailsLine(text(DetailsText.TMUX_SESSION), shown(tmux.session))
            lines += DetailsLine(
                text(DetailsText.TMUX_IDS_LABEL),
                when {
                    tmux.live && tmux.sessionID != null && tmux.paneID != null -> text(DetailsText.TMUX_IDS).format(tmux.sessionID, tmux.paneID)
                    tmux.live -> shown(tmux.sessionID)
                    // Si no se pudo mirar, no se sabe si está en marcha: decir que no sería mentir.
                    unreachable -> text(DetailsText.TMUX_UNCHECKED)
                    else -> text(DetailsText.TMUX_NOT_LIVE)
                },
            )
        }
        val agent = details.agent
        lines += DetailsLine(
            text(DetailsText.AGENT),
            when {
                // Gana aunque haya algo guardado: lo que corre ahora no es una sola IA.
                reason == DetailsReason.AMBIGUOUS -> text(DetailsText.AGENT_AMBIGUOUS)
                agent == null && unreachable -> text(DetailsText.AGENT_NONE_SAVED)
                agent == null -> text(DetailsText.AGENT_NONE)
                agent.sessionID == null && (agent.stateKind == DetailsAgentState.ACTIVE || reason == DetailsReason.NO_ID) ->
                    text(DetailsText.AGENT_NO_ID_LIVE).format(agent.name)
                agent.sessionID == null -> text(DetailsText.AGENT_NO_ID_SAVED).format(agent.name)
                else -> agent.name
            },
        )
        if (agent == null) return DetailsSheet(notice, lines, commandNote = null)
        lines += DetailsLine(
            text(DetailsText.STATE),
            when (agent.stateKind) {
                DetailsAgentState.ACTIVE -> text(DetailsText.STATE_ACTIVE)
                DetailsAgentState.INTERRUPTED -> text(DetailsText.STATE_INTERRUPTED)
                // Guardada y la ventana ahora en un shell: no es «sin comprobar», se comprobó y no hay IA.
                DetailsAgentState.SAVED -> if (reason == DetailsReason.NO_AGENT) text(DetailsText.STATE_SAVED_SHELL) else text(DetailsText.STATE_SAVED)
                null -> shown(agent.state)
            },
        )
        lines += DetailsLine(text(DetailsText.SESSION), shown(agent.sessionID), DetailsLineKind.CODE)
        lines += DetailsLine(text(DetailsText.CWD), shown(agent.cwd), DetailsLineKind.CODE)
        if (details.isSSH) {
            lines += DetailsLine(
                text(DetailsText.AS_ROOT),
                when (agent.asRoot) {
                    true -> text(DetailsText.YES)
                    false -> text(DetailsText.NO)
                    null -> empty
                },
            )
        }
        lines += DetailsLine(
            text(DetailsText.SOURCE),
            when (agent.sourceKind) {
                DetailsSource.SESSION_FILE -> text(DetailsText.SOURCE_FICHA)
                DetailsSource.ROLLOUT -> text(DetailsText.SOURCE_ROLLOUT)
                DetailsSource.ARGV -> text(DetailsText.SOURCE_ARGV)
                DetailsSource.HOOK -> text(DetailsText.SOURCE_HOOK)
                DetailsSource.MANIFEST -> text(DetailsText.SOURCE_MANIFIESTO)
                DetailsSource.RECORD -> text(DetailsText.SOURCE_REGISTRO)
                null -> shown(agent.source)
            },
        )
        val resume = agent.resume ?: return DetailsSheet(notice, lines, commandNote = null)
        lines += DetailsLine(text(DetailsText.RESUME), resume.command, DetailsLineKind.COMMAND)
        return DetailsSheet(notice, lines, commandNote = if (resume.noPromptVerified) null else text(DetailsText.NO_PROMPT_UNVERIFIED))
    }
}
