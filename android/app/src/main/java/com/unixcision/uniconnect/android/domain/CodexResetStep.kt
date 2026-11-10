package com.unixcision.uniconnect.android.domain

/**
 * Dónde está un reseteo gratis de Codex: nada, pidiendo confirmación, en marcha, hecho o fallido.
 *
 * La clave de idempotencia nace **una vez por confirmación** ([ask]) y viaja intacta a [confirm] y
 * a [retry]: un reintento tras un corte nunca gasta un segundo reseteo, porque Codex reconoce la
 * misma clave (`alreadyRedeemed`). Una confirmación nueva, después de cancelar o de terminar, lleva
 * una clave nueva.
 */
sealed interface CodexResetStep {
    data object Idle : CodexResetStep

    /** Esperando el «Gastar reseteo». */
    data class Confirming(val target: CodexResetTarget, val idempotencyKey: String) : CodexResetStep

    /** Pedido al equipo; el botón queda deshabilitado con un indicador. */
    data class Running(val target: CodexResetTarget, val idempotencyKey: String) : CodexResetStep

    /** El equipo contestó. */
    data class Done(val target: CodexResetTarget, val result: CodexResetResult) : CodexResetStep

    /** No se supo cómo acabó; [retry] lo repite con la misma clave. */
    data class Failed(val target: CodexResetTarget, val idempotencyKey: String, val failure: AccountsFailure) : CodexResetStep

    companion object {
        /** Abre la confirmación de [target] con una clave recién creada por [newKey]. */
        fun ask(target: CodexResetTarget, newKey: () -> String): Confirming = Confirming(target, newKey())

        /** El «Gastar reseteo»: en marcha con la clave de la confirmación. */
        fun confirm(step: Confirming): Running = Running(step.target, step.idempotencyKey)

        /** Reintentar un fallo: la misma clave, para que no se gaste dos veces. */
        fun retry(step: Failed): Running = Running(step.target, step.idempotencyKey)
    }
}
