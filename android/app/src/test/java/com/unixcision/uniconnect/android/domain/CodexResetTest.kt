package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.Instant

/**
 * Gastar un reseteo gratis de Codex (§5), la única escritura de accounts-v1: cuándo se ofrece, qué
 * se dice según lo que conteste Codex y que la clave de idempotencia no cambie al reintentar.
 */
class CodexResetTest {
    private val email = "ana@ejemplo.com"

    private fun account(
        provider: String = "codex",
        available: Int? = 2,
        hostKey: String? = "local",
        machineID: String? = "mac",
        accountEmail: String? = email,
    ) = UsageAccount(
        key = "$provider:$accountEmail", provider = provider, displayName = "Codex", email = accountEmail, plan = "Pro",
        windows = 1, hosts = listOf("Mac · Este Mac"),
        usage = AccountUsage(
            "app_server", Instant.parse("2026-11-10T12:30:04Z"),
            listOf(UsageLimit("primary", 83.0, Instant.parse("2026-11-11T10:50:07Z"), 10_080)), hostKey,
            available?.let { ResetCredits(it, Instant.parse("2026-11-30T20:02:00Z")) },
        ),
        seenOn = "Mac · Este Mac", history = emptyList(), rows = emptyList(), usageMachineID = machineID,
    )

    private val capable = setOf("mac")

    @Test fun `se ofrece en Codex con reseteos, host conocido y un equipo que sabe hacerlo`() {
        assertEquals(CodexResetTarget("mac", "codex:$email", "local", email, 2), CodexResetTarget.of(account(), capable))
    }

    @Test fun `no se ofrece si falta cualquiera de las condiciones`() {
        assertNull(CodexResetTarget.of(account(provider = "claude"), capable))
        assertNull(CodexResetTarget.of(account(available = 0), capable))
        assertNull(CodexResetTarget.of(account(available = null), capable))
        assertNull(CodexResetTarget.of(account(hostKey = null), capable))
        assertNull(CodexResetTarget.of(account(machineID = null), capable))
        assertNull(CodexResetTarget.of(account(accountEmail = null), capable))
        // El equipo donde se vio el uso no anuncia accounts.codex_reset.v1.
        assertNull(CodexResetTarget.of(account(), setOf("minipc")))
        assertNull(CodexResetTarget.of(account().copy(usage = null), capable))
    }

    @Test fun `la clave nace una vez por confirmacion y no cambia al reintentar`() {
        var issued = 0
        val newKey = { "clave-${++issued}" }
        val target = requireNotNull(CodexResetTarget.of(account(), capable))

        val asked = CodexResetStep.ask(target, newKey)
        val running = CodexResetStep.confirm(asked)
        assertEquals("clave-1", running.idempotencyKey)
        val failed = CodexResetStep.Failed(target, running.idempotencyKey, AccountsFailure(AccountsFailure.Kind.UNREACHABLE))
        assertEquals("clave-1", CodexResetStep.retry(failed).idempotencyKey)
        assertEquals("clave-1", CodexResetStep.retry(CodexResetStep.Failed(target, "clave-1", AccountsFailure(AccountsFailure.Kind.UNREACHABLE))).idempotencyKey)
        // Una confirmación nueva es otra clave.
        assertNotEquals(running.idempotencyKey, CodexResetStep.confirm(CodexResetStep.ask(target, newKey)).idempotencyKey)
        assertEquals(2, issued)
    }

    @Test fun `cada outcome de Codex tiene su mensaje`() {
        val target = requireNotNull(CodexResetTarget.of(account(), capable))
        fun done(outcome: String) = CodexResetMessage.of(CodexResetStep.Done(target, CodexResetResult(target.accountKey, "local", outcome, null)))
        assertEquals(CodexResetMessage.DONE, done("reset"))
        assertEquals(CodexResetMessage.NOTHING_TO_RESET, done("nothingToReset"))
        assertEquals(CodexResetMessage.NO_CREDIT, done("noCredit"))
        assertEquals(CodexResetMessage.ALREADY_REDEEMED, done("alreadyRedeemed"))
        assertEquals(CodexResetMessage.UNKNOWN_OUTCOME, done("algoNuevo"))
        assertEquals(CodexResetMessage.UNKNOWN_OUTCOME, done(""))
        assertEquals(CodexResetOutcome.ALREADY_REDEEMED, CodexResetOutcome.named("alreadyRedeemed"))
    }

    @Test fun `cada error de la llamada tiene el suyo, y mientras va no hay mensaje`() {
        val target = requireNotNull(CodexResetTarget.of(account(), capable))
        fun failed(failure: AccountsFailure) = CodexResetMessage.of(CodexResetStep.Failed(target, "k", failure))
        assertEquals(CodexResetMessage.NOT_FOUND, failed(AccountsFailure.of(MachineFailure.Rejected("not_found"))))
        assertEquals(CodexResetMessage.UNAVAILABLE, failed(AccountsFailure.of(MachineFailure.Rejected("unavailable"))))
        assertEquals(CodexResetMessage.INVALID, failed(AccountsFailure.of(MachineFailure.Rejected("invalid_params"))))
        assertEquals(CodexResetMessage.LOCKED, failed(AccountsFailure.of(MachineFailure.Rejected("locked"))))
        assertEquals(CodexResetMessage.UNSUPPORTED, failed(AccountsFailure.of(MachineFailure.Rejected("method_not_found"))))
        assertEquals(CodexResetMessage.UNREACHABLE, failed(AccountsFailure.of(MachineFailure.DeadlineExceeded())))
        assertEquals(CodexResetMessage.UNREACHABLE, failed(AccountsFailure.of(MachineFailure.ProtocolMismatch())))
        assertEquals(CodexResetMessage.OTHER, failed(AccountsFailure.of(MachineFailure.Rejected("raro"))))
        assertNull(CodexResetMessage.of(CodexResetStep.Running(target, "k")))
        assertNull(CodexResetMessage.of(CodexResetStep.Confirming(target, "k")))
        assertNull(CodexResetMessage.of(CodexResetStep.Idle))
    }
}
