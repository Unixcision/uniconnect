package com.unixcision.uniconnect.android.ui

import com.unixcision.uniconnect.android.domain.AccountChip
import com.unixcision.uniconnect.android.domain.AccountHost
import com.unixcision.uniconnect.android.domain.AccountInfo
import com.unixcision.uniconnect.android.domain.AccountNotice
import com.unixcision.uniconnect.android.domain.AccountWindow
import com.unixcision.uniconnect.android.domain.AccountsFailure
import com.unixcision.uniconnect.android.domain.AccountsQuery
import com.unixcision.uniconnect.android.domain.AccountsReport
import com.unixcision.uniconnect.android.domain.Machine
import com.unixcision.uniconnect.android.domain.MachineEndpoint
import com.unixcision.uniconnect.android.domain.MachineFailure
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

/**
 * La frescura de «Cuentas de IA»: cada pasada sustituye a la anterior, un equipo que falla se
 * queda sin filas en vez de con las viejas, dos peticiones a la vez comparten una lectura y al
 * salir de la pantalla no queda nada que volver a pintar.
 */
class AccountsViewModelTest {
    private val mac = Machine("mac", "Mac", requireNotNull(MachineEndpoint.parse("100.64.0.1", "58465")))
    private val minipc = Machine("minipc", "MINIPC", requireNotNull(MachineEndpoint.parse("100.64.0.2", "58465")))
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @After fun limpiar() { scope.cancel() }

    private fun report(email: String, checkedAt: String = "2026-11-10T12:30:06Z") = AccountsReport(
        version = 1, checkedAt = checkedAt,
        hosts = listOf(AccountHost("local", "Este equipo", "local", AccountHost.OK, checkedAt)),
        windows = listOf(
            AccountWindow(
                "ws", "PROYECTOS", "t1", "uniconnect", "local", "uc-1", "ok", null,
                AccountInfo(email = email, method = "oauth", osUser = "dani", config = "/home/dani/.claude.json"),
            ),
        ),
    )

    @Test fun `un equipo que falla se queda sin filas, nunca con las de antes`() = runBlocking {
        var minipcAnswers = true
        val model = AccountsViewModel({ machine ->
            when {
                machine.id == mac.id -> report("dev@notbetting.com")
                minipcAnswers -> report("it@iberiavo.com")
                else -> throw MachineFailure.DeadlineExceeded()
            }
        }, scope)

        model.refresh(listOf(mac, minipc))
        assertEquals(setOf("dev@notbetting.com", "it@iberiavo.com"), model.state.value.board?.rows?.mapNotNull { it.email }?.toSet())

        minipcAnswers = false
        model.refresh(listOf(mac, minipc))
        val board = requireNotNull(model.state.value.board)
        assertEquals(listOf("dev@notbetting.com"), board.rows.mapNotNull { it.email })
        assertEquals(listOf(AccountNotice.MachineFailed("MINIPC", AccountsFailure(AccountsFailure.Kind.UNREACHABLE))), board.notices)
        assertFalse(model.state.value.reading)
    }

    @Test fun `el codigo del equipo dice por que no se pudo leer`() = runBlocking {
        val model = AccountsViewModel({ throw MachineFailure.Rejected("locked", "UniConnect está bloqueado.") }, scope)
        model.refresh(listOf(mac))
        val notice = model.state.value.board?.notices?.single() as AccountNotice.MachineFailed
        assertEquals(AccountsFailure.Kind.LOCKED, notice.failure.kind)
        assertEquals(AccountsFailure.Kind.UNSUPPORTED, AccountsFailure.of(MachineFailure.Rejected("method_not_found")).kind)
        assertEquals(AccountsFailure.Kind.MALFORMED, AccountsFailure.of(MachineFailure.ProtocolMismatch()).kind)
        assertEquals(AccountsFailure.Kind.UNREACHABLE, AccountsFailure.of(MachineFailure.Transport()).kind)
    }

    @Test fun `dos peticiones a la vez comparten una sola lectura`() = runBlocking {
        val calls = AtomicInteger()
        val gate = CompletableDeferred<Unit>()
        val model = AccountsViewModel({ calls.incrementAndGet(); gate.await(); report("dev@notbetting.com") }, scope)

        val first = scope.async { model.refresh(listOf(mac)) }
        withTimeout(5_000) { model.state.first { it.reading } }
        val second = scope.async { model.refresh(listOf(mac)) }
        gate.complete(Unit)
        withTimeout(5_000) { listOf(first, second).awaitAll() }

        assertEquals(1, calls.get())
        assertEquals(listOf("dev@notbetting.com"), model.state.value.board?.rows?.mapNotNull { it.email })
    }

    @Test fun `al salir de la pantalla se olvida la lectura`() = runBlocking {
        val model = AccountsViewModel({ report("dev@notbetting.com") }, scope)
        model.refresh(listOf(mac))
        assertTrue(model.state.value.board != null)

        model.stop()

        assertNull(model.state.value.board)
        assertFalse(model.state.value.reading)
    }

    @Test fun `una lectura cortada al salir no vuelve a pintar nada`() = runBlocking {
        val gate = CompletableDeferred<Unit>()
        val model = AccountsViewModel({ gate.await(); report("dev@notbetting.com") }, scope)
        val pass = scope.async { runCatching { model.refresh(listOf(mac)) } }
        withTimeout(5_000) { model.state.first { it.reading } }

        model.stop()
        gate.complete(Unit)
        withTimeout(5_000) { pass.await() }

        assertNull(model.state.value.board)
        assertFalse(model.state.value.reading)
    }

    @Test fun `filtros y agrupacion sobreviven a cada pasada`() = runBlocking {
        val model = AccountsViewModel({ report("dev@notbetting.com") }, scope)
        model.choose(AccountChip.Email("dev@notbetting.com"))
        model.group(AccountsQuery.Grouping.BY_ACCOUNT)
        model.search("proyectos")
        model.showWithoutAgent(true)
        model.refresh(listOf(mac))
        model.refresh(listOf(mac))
        assertEquals(
            AccountsQuery(AccountChip.Email("dev@notbetting.com"), "proyectos", AccountsQuery.Grouping.BY_ACCOUNT, showWithoutAgent = true),
            model.state.value.query,
        )
    }
}
