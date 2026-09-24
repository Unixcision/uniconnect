package com.unixcision.uniconnect.android.domain

/**
 * Cada texto del modal «Detalles», con el nombre de su recurso en `res/values/strings.xml`.
 *
 * El texto de verdad vive en `strings.xml` (solo español) y es, letra por letra, el de la tabla de
 * `contracts/window-details-v1/LEEME.md`: el mismo que enseñan el Mac y Linux. Los que llevan
 * `%1$s` son plantillas que rellena [WindowDetailsRows].
 *
 * [resource] existe para que las pruebas JVM, que no tienen `Resources`, rendericen con el mismo
 * `strings.xml` y lo comparen con `filas.json`.
 */
enum class DetailsText(val resource: String) {
    WORKSPACE("details_workspace"),
    KIND("details_kind"),
    KIND_LOCAL("details_kind_local"),

    /** «VPS (%1$s)», con la etiqueta `usuario@host:puerto`. */
    KIND_SSH("details_kind_ssh"),
    KIND_SSH_UNNAMED("details_kind_ssh_unnamed"),
    WINDOW("details_window"),
    TMUX_SOCKET("details_tmux_socket"),
    TMUX_DEFAULT("details_tmux_default"),
    TMUX_SESSION("details_tmux_session"),

    /** El valor de la fila «Sesión tmux» de una ventana antigua sin tmux. */
    TMUX_NONE("details_tmux_none"),
    TMUX_IDS_LABEL("details_tmux_ids_label"),

    /** «%1$s · %2$s»: `$N` y `%N` en vivo. */
    TMUX_IDS("details_tmux_ids"),
    TMUX_NOT_LIVE("details_tmux_not_live"),

    /** La comprobación en vivo falló: no se sabe si está en marcha. */
    TMUX_UNCHECKED("details_tmux_unchecked"),
    AGENT("details_agent"),
    AGENT_AMBIGUOUS("details_agent_ambiguous"),

    /** Sin IA guardada y sin poder comprobar ahora. */
    AGENT_NONE_SAVED("details_agent_none_saved"),
    AGENT_NONE("details_agent_none"),

    /** «%1$s: IA detectada, sin identificador todavía». */
    AGENT_NO_ID_LIVE("details_agent_no_id_live"),

    /** «%1$s: sin identificador guardado». */
    AGENT_NO_ID_SAVED("details_agent_no_id_saved"),
    STATE("details_state"),
    STATE_ACTIVE("details_state_active"),
    STATE_INTERRUPTED("details_state_interrupted"),

    /** Guardada y la ventana ahora en un shell (`reason = sin_ia`). */
    STATE_SAVED_SHELL("details_state_saved_shell"),
    STATE_SAVED("details_state_saved"),
    SESSION("details_session"),
    CWD("details_cwd"),
    AS_ROOT("details_as_root"),
    YES("details_yes"),
    NO("details_no"),
    SOURCE("details_source"),
    SOURCE_FICHA("details_source_ficha"),
    SOURCE_ROLLOUT("details_source_rollout"),
    SOURCE_ARGV("details_source_argv"),
    SOURCE_HOOK("details_source_hook"),
    SOURCE_MANIFIESTO("details_source_manifiesto"),
    SOURCE_REGISTRO("details_source_registro"),
    RESUME("details_resume"),
    NO_PROMPT_UNVERIFIED("details_no_prompt_unverified"),

    /** El aviso de arriba cuando no se pudo comprobar una ventana SSH. */
    UNREACHABLE_SSH("details_host_unreachable"),

    /** El mismo aviso en una ventana local. */
    UNREACHABLE_LOCAL("details_host_unreachable_local"),

    /** Lo que se enseña en lugar de un valor vacío o `null`. */
    EMPTY("details_empty"),
}
