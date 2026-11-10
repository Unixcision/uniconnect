package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

/**
 * «Uso por cuenta» con varios equipos: la misma cuenta en el Mac y en el MINIPC se junta en una, con
 * el uso más reciente de los dos y los históricos mezclados por fecha; y la gráfica de 7 días.
 */
class UsageAccountsTest {
    private val ana = "ana@ejemplo.com"
    private val luis = "luis@ejemplo.com"

    private fun at(iso: String) = Instant.parse(iso)

    private fun host(key: String, label: String) = AccountHost(key, label, if (key == "local") "local" else "ssh", AccountHost.OK, null)

    private fun window(id: String, name: String, hostKey: String, email: String) = AccountWindow(
        "ws-$id", "ESPACIO", id, name, hostKey, "uc-$id", "ok", AccountAgent("claude", "Claude Code", false),
        AccountInfo(email = email, method = "oauth"),
    )

    private fun usage(observed: String, percent: Double, hostKey: String) = AccountUsage(
        "statusline", at(observed), listOf(UsageLimit("seven_day", percent, at("2026-11-15T14:00:00Z"), 10_080)), hostKey,
    )

    private fun summary(windows: Int, hostKeys: List<String>, usage: AccountUsage?, history: List<UsageSample>) = AccountSummary(
        "claude:$ana", "claude", "Claude Code", ana, "Ultra", null, windows, hostKeys, usage, history,
    )

    private val mac = MachineAccounts("mac", "Mac", AccountsReport(
        1, "2026-11-10T12:30:06Z", listOf(host("local", "Este Mac")),
        listOf(window("m1", "uniconnect", "local", ana)),
        listOf(summary(1, listOf("local"), usage("2026-11-10T12:12:40Z", 50.0, "local"), listOf(UsageSample(at("2026-11-10T12:12:40Z"), mapOf("seven_day" to 50.0))))),
    ))
    private val minipc = MachineAccounts("minipc", "MINIPC", AccountsReport(
        1, "2026-11-10T12:30:05Z", listOf(host("local", "Este equipo"), host("ssh:root@203.0.113.10:22", "root@203.0.113.10:22")),
        listOf(window("p1", "APP 2", "ssh:root@203.0.113.10:22", ana), window("p2", "otra", "local", luis)),
        listOf(summary(1, listOf("ssh:root@203.0.113.10:22"), usage("2026-11-10T12:29:58Z", 51.0, "ssh:root@203.0.113.10:22"), listOf(UsageSample(at("2026-11-09T09:00:00Z"), mapOf("seven_day" to 31.0))))),
    ))

    @Test fun `la misma cuenta en dos equipos es una sola`() {
        val account = AccountsBoard(listOf(mac, minipc)).usageAccounts.single()
        assertEquals("claude:$ana", account.key)
        assertEquals(2, account.windows)
        assertEquals(listOf("Mac · Este Mac", "MINIPC · root@203.0.113.10:22"), account.hosts)
        // El uso más reciente gana, con el host y el equipo donde se vio.
        assertEquals(at("2026-11-10T12:29:58Z"), account.usage?.observedAt)
        assertEquals("MINIPC · root@203.0.113.10:22", account.seenOn)
        assertEquals(listOf(at("2026-11-09T09:00:00Z"), at("2026-11-10T12:12:40Z")), account.history.map { it.at })
        // «Dónde está»: sus ventanas de esta pasada, no las de otra cuenta.
        assertEquals(listOf("uniconnect", "APP 2"), account.rows.map { it.window.window })
        assertEquals(AccountPalette.indexOf(ana), account.colorIndex)
    }

    @Test fun `un equipo que no contesta no aporta ni uso ni historico`() {
        val failed = MachineAccounts("minipc", "MINIPC", null, AccountsFailure(AccountsFailure.Kind.UNREACHABLE))
        val account = AccountsBoard(listOf(mac, failed)).usageAccounts.single()
        assertEquals(1, account.windows)
        assertEquals("Mac · Este Mac", account.seenOn)
        assertEquals(1, account.history.size)
    }

    @Test fun `la grafica junta historico y uso actual dentro de los 7 dias, y marca los resets`() {
        val now = at("2026-11-10T12:30:06Z")
        val account = AccountsBoard(listOf(mac, minipc)).usageAccounts.single().copy(
            history = listOf(
                UsageSample(at("2026-11-02T09:00:00Z"), mapOf("seven_day" to 99.0)),
                UsageSample(at("2026-11-09T09:00:00Z"), mapOf("seven_day" to 31.0)),
                UsageSample(at("2026-11-10T08:00:00Z"), mapOf("seven_day" to 47.0, "five_hour" to 0.0)),
            ),
        )
        val chart = UsageChart.of(account, now)
        assertEquals(now.minus(UsageChart.SPAN), chart.start)
        assertEquals(listOf("seven_day", "five_hour"), chart.series.map { it.id })
        assertEquals(LimitName.Week, chart.series.first().name)
        // La muestra del 02-11 cae fuera de los 7 días; el uso actual entra como punto más nuevo.
        assertEquals(
            listOf(at("2026-11-09T09:00:00Z") to 31.0, at("2026-11-10T08:00:00Z") to 47.0, at("2026-11-10T12:29:58Z") to 51.0),
            chart.series.first().points,
        )
        // El comienzo de la ventana semanal actual (15-11 14:00 − 7 d) es un reset de esta semana.
        assertEquals(listOf(at("2026-11-08T14:00:00Z")), chart.resets)
        assertFalse(chart.isEmpty)
    }

    @Test fun `sin historico ni uso la grafica esta vacia`() {
        val empty = UsageAccount("codex:$luis", "codex", "Codex", luis, "Pro", 1, emptyList(), null, null, emptyList(), emptyList())
        assertTrue(UsageChart.of(empty, at("2026-11-10T12:30:06Z")).isEmpty)
        assertNull(empty.usage)
    }
}
