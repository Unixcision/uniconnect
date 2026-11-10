package com.unixcision.uniconnect.android.domain

/**
 * Qué se le dice a quien gastó (o intentó gastar) un reseteo gratis de Codex (§5). La frase la pone
 * la pantalla; esto decide cuál.
 */
enum class CodexResetMessage {
    /** `reset`: «Hecho: <email> vuelve a empezar.» */
    DONE,
    /** `nothingToReset`: no se ha gastado ninguno. */
    NOTHING_TO_RESET,
    /** `noCredit`: la cuenta ya no tiene reseteos. */
    NO_CREDIT,
    /** `alreadyRedeemed`: esa clave ya lo había aplicado. */
    ALREADY_REDEEMED,
    /** Un `outcome` que esta versión no conoce: se enseña tal cual. */
    UNKNOWN_OUTCOME,
    /** `not_found`: no hay ninguna ventana de esa cuenta en ese host. */
    NOT_FOUND,
    /** `unavailable`: el host no contestó o no hay Codex al que preguntar; no se gastó nada. */
    UNAVAILABLE,
    /** `locked`: UniConnect está bloqueado en el equipo. */
    LOCKED,
    /** `invalid_params`. */
    INVALID,
    /** `method_not_found`: el equipo no sabe hacerlo. */
    UNSUPPORTED,
    /** Se cortó o no contestó a tiempo: no se sabe si se gastó; reintentar no gasta dos. */
    UNREACHABLE,
    /** Otro error, con su código. */
    OTHER;

    companion object {
        /** El mensaje de un reseteo terminado o fallido; nulo mientras no lo está. */
        fun of(step: CodexResetStep): CodexResetMessage? = when (step) {
            is CodexResetStep.Done -> when (step.result.outcome) {
                CodexResetOutcome.RESET -> DONE
                CodexResetOutcome.NOTHING_TO_RESET -> NOTHING_TO_RESET
                CodexResetOutcome.NO_CREDIT -> NO_CREDIT
                CodexResetOutcome.ALREADY_REDEEMED -> ALREADY_REDEEMED
                CodexResetOutcome.UNKNOWN -> UNKNOWN_OUTCOME
            }
            is CodexResetStep.Failed -> when (step.failure.kind) {
                AccountsFailure.Kind.LOCKED -> LOCKED
                AccountsFailure.Kind.UNSUPPORTED -> UNSUPPORTED
                AccountsFailure.Kind.UNREACHABLE, AccountsFailure.Kind.MALFORMED -> UNREACHABLE
                AccountsFailure.Kind.REJECTED -> when (step.failure.code) {
                    "not_found" -> NOT_FOUND
                    "unavailable" -> UNAVAILABLE
                    "invalid_params" -> INVALID
                    else -> OTHER
                }
            }
            CodexResetStep.Idle, is CodexResetStep.Confirming, is CodexResetStep.Running -> null
        }
    }
}
