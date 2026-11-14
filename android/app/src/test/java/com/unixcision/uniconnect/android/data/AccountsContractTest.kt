package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.AccountChip
import com.unixcision.uniconnect.android.domain.AccountChipCount
import com.unixcision.uniconnect.android.domain.AccountGroup
import com.unixcision.uniconnect.android.domain.AccountHost
import com.unixcision.uniconnect.android.domain.AccountLabel
import com.unixcision.uniconnect.android.domain.AccountMethod
import com.unixcision.uniconnect.android.domain.AccountNotice
import com.unixcision.uniconnect.android.domain.AccountPalette
import com.unixcision.uniconnect.android.domain.AccountRow
import com.unixcision.uniconnect.android.domain.AccountStatus
import com.unixcision.uniconnect.android.domain.AccountUsageMath
import com.unixcision.uniconnect.android.domain.LimitName
import com.unixcision.uniconnect.android.domain.AccountWindowState
import com.unixcision.uniconnect.android.domain.AccountsBoard
import com.unixcision.uniconnect.android.domain.AccountsFailure
import com.unixcision.uniconnect.android.domain.AccountsQuery
import com.unixcision.uniconnect.android.domain.AccountsReport
import com.unixcision.uniconnect.android.domain.MachineAccounts
import com.unixcision.uniconnect.android.domain.ProviderChipCount
import com.unixcision.uniconnect.android.domain.ResetCredits
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.ZoneId

/**
 * «Cuentas de IA» por el decodificador real contra `contracts/accounts-v1/accounts-response.json`, y
 * los filtros y la agrupación del §4 sobre esa misma respuesta: lo que de verdad llega del equipo.
 */
class AccountsContractTest {
    private val client = NativeMachineClient(FramedRpcClient(CoroutineScope(Dispatchers.Unconfined)))

    private fun fixture(name: String): JSONObject = JSONObject(
        requireNotNull(javaClass.classLoader?.getResourceAsStream("accounts-v1/$name"))
            { "falta el fixture del contrato: contracts/accounts-v1/$name" }
            .bufferedReader().readText()
    )

    private val report: AccountsReport by lazy { client.decodeAccounts(fixture("accounts-response.json")) }
    private val board: AccountsBoard by lazy { AccountsBoard(listOf(MachineAccounts("mac", "Mac", report))) }

    private fun window(name: String) = board.rows.single { it.window.window == name }

    @Test fun `la respuesta del contrato se lee entera`() {
        assertEquals(1, report.version)
        assertEquals("2026-11-10T12:30:06Z", report.checkedAt)
        assertEquals(6, report.hosts.size)
        assertEquals(12, report.windows.size)
        assertEquals(
            listOf(AccountHost.OK, AccountHost.OK, AccountHost.OK, AccountHost.UNREACHABLE, AccountHost.OK, AccountHost.VAULT_LOCKED),
            report.hosts.map { it.state },
        )

        val uniconnect = report.windows.first()
        assertEquals("11111111-1111-4111-8111-111111111111", uniconnect.workspaceID)
        assertEquals("PROYECTOS", uniconnect.workspace)
        assertEquals("a1111111-1111-4111-8111-111111111111", uniconnect.terminalID)
        assertEquals("local", uniconnect.hostKey)
        assertEquals(AccountWindowState.OK, uniconnect.state)
        assertEquals("Claude Code", uniconnect.agent?.displayName)
        assertEquals(false, uniconnect.agent?.asRoot)
        assertEquals("dev@notbetting.com", uniconnect.account?.email)
        assertEquals("oauth", uniconnect.account?.method)
        assertEquals("Ultra", uniconnect.account?.plan)
        assertEquals("/Users/danielgomezmartin/.claude.json", uniconnect.account?.config)
        assertEquals("2026-11-10T12:30:04Z", uniconnect.account?.readAt)
    }

    @Test fun `cada host dice por que no se leyo`() {
        assertEquals(listOf(null, null, null, "ssh_fallo", null, null), report.hosts.map { it.error })
        assertEquals("ec2-user@54.167.34.64: Permission denied (publickey).", report.hosts[3].errorDetail)
        assertTrue(report.hosts.filterIndexed { index, _ -> index != 3 }.all { it.errorDetail == null })
    }

    @Test fun `el filtro por IA sale de lo que hay, de mas a menos ventanas`() {
        // Visibles sin «Ventanas sin IA»: Claude en 4, Codex en 2, Antigravity en 1, y 3 sin IA que no cuentan.
        assertEquals(
            listOf(
                ProviderChipCount(null, null, 7), ProviderChipCount("claude", "Claude Code", 4),
                ProviderChipCount("codex", "Codex", 2), ProviderChipCount("agy", "Antigravity", 1),
            ),
            board.providerChips(AccountsQuery()),
        )
        // Las ventanas sin IA tampoco cuentan cuando se enseñan.
        assertEquals(7, board.providerChips(AccountsQuery(showWithoutAgent = true)).first().count)
    }

    @Test fun `elegir una IA deja solo sus ventanas y sus cuentas`() {
        val codex = AccountsQuery(provider = "codex")
        assertEquals(listOf("impuestos", "codex-antiresell"), board.filtered(codex).map { it.window.window })
        val codexEmails = report.windows.filter { it.agent?.provider == "codex" }.mapNotNull { it.account?.email }.toSet()
        val chips = board.chips(codex)
        assertEquals(2, chips.first().count)
        assertEquals(codexEmails, chips.mapNotNull { (it.chip as? AccountChip.Email)?.email }.toSet())
        assertEquals(listOf(0, 0), chips.takeLast(2).map { it.count })
        // Y en «Uso por cuenta», solo las cuentas de Codex.
        assertEquals(report.accounts.filter { it.provider == "codex" }.map { it.key }, board.usageAccounts(codex).map { it.key })
        assertEquals(board.usageAccounts, board.usageAccounts(AccountsQuery()))
    }

    @Test fun `por IA, una seccion por IA y Sin IA al final`() {
        val groups = board.groups(AccountsQuery(grouping = AccountsQuery.Grouping.BY_AGENT))
        assertEquals(
            listOf(
                AccountGroup.Key.Agent("claude", "Claude Code"), AccountGroup.Key.Agent("codex", "Codex"),
                AccountGroup.Key.Agent("agy", "Antigravity"), AccountGroup.Key.NoAgent,
            ),
            groups.map { it.key },
        )
        assertEquals(listOf(4, 2, 1, 3), groups.map { it.rows.size })
        // Claude: dos ventanas con la misma cuenta leída, una sin sesión y otra no legible → 1 cuenta.
        assertEquals(listOf(1, 2, 0, 0), groups.map { it.accountCount })
        assertEquals(listOf("vieja", "iberiavochatbot", "api"), groups.last().rows.map { it.window.window })
    }

    @Test fun `un null del contrato es nulo, nunca el texto null`() {
        val impuestos = report.windows[1]
        assertNull(impuestos.account?.organization)
        val antigua = report.windows.single { it.window == "antigua" }
        assertNull(antigua.tmuxSession)
        assertNull(antigua.agent)
        assertNull(antigua.account)
        val agy = report.windows.single { it.window == "agy" }
        assertNull(agy.account?.config)
        assertNull(agy.account?.email)
    }

    @Test fun `cada estado del contrato se entiende`() {
        assertEquals(
            setOf("ok", "sin_ia", "sesion_no_viva", "sin_sesion", "host_inaccesible", "no_legible", "desconocida", "sin_tmux"),
            report.windows.map { it.stateWire }.toSet(),
        )
        assertTrue(report.windows.all { it.state != null })
    }

    @Test fun `las fichas cuentan lo visible, cuentas de mas a menos y luego sin sesion y sin leer`() {
        // Con «Ventanas sin IA» apagado se ocultan `zsh` (sin_ia) y `antigua` (sin_tmux).
        assertEquals(
            listOf(
                AccountChipCount(AccountChip.All, 10),
                AccountChipCount(AccountChip.Email("dev@notbetting.com"), 2, 3),
                AccountChipCount(AccountChip.Email("it@iberiavo.com"), 1, 2),
                AccountChipCount(AccountChip.Email("subs@iberiavo.com"), 1, 4),
                AccountChipCount(AccountChip.NoSession, 1),
                // vieja, iberiavochatbot, claudefix (root), agy y api.
                AccountChipCount(AccountChip.Unread, 5),
            ),
            board.chips(AccountsQuery()),
        )
        assertEquals(AccountChipCount(AccountChip.All, 12), board.chips(AccountsQuery(showWithoutAgent = true)).first())
    }

    @Test fun `una ficha de cuenta se queda solo con sus ventanas`() {
        val dev = board.filtered(AccountsQuery(chip = AccountChip.Email("dev@notbetting.com")))
        assertEquals(listOf("uniconnect", "APP 2"), dev.map { it.window.window })
        val sinLeer = board.filtered(AccountsQuery(chip = AccountChip.Unread))
        assertEquals(listOf("vieja", "iberiavochatbot", "claudefix (root)", "agy", "api"), sinLeer.map { it.window.window })
        assertEquals(listOf("bot noleakos"), board.filtered(AccountsQuery(chip = AccountChip.NoSession)).map { it.window.window })
    }

    @Test fun `el buscador mira espacio, ventana, email, host y usuario`() {
        assertEquals(
            listOf("impuestos", "codex-antiresell", "iberiavochatbot"),
            board.filtered(AccountsQuery(search = "IBERIAVO")).map { it.window.window },
        )
        // Cada palabra tiene que estar: el espacio MINIPC y el usuario root.
        assertEquals(listOf("claudefix (root)"), board.filtered(AccountsQuery(search = " minipc  root ")).map { it.window.window })
        assertEquals(listOf("api"), board.filtered(AccountsQuery(search = "198.51.100.7")).map { it.window.window })
        assertEquals(10, board.filtered(AccountsQuery(search = "   ")).size)
    }

    @Test fun `por espacio, en el orden de la barra lateral`() {
        val groups = board.groups(AccountsQuery())
        assertEquals(
            listOf("PROYECTOS", "NOTBETTING", "NOLEAKOS", "IBERIAVO-PREPRO", "MINIPC", "CLIENTE"),
            groups.map { (it.key as AccountGroup.Key.Workspace).name },
        )
        assertEquals(listOf("uniconnect", "impuestos"), groups.first().rows.map { it.window.window })
        // Con el interruptor encendido vuelven las ventanas sin IA, en su sitio.
        val all = board.groups(AccountsQuery(showWithoutAgent = true))
        assertEquals(listOf("uniconnect", "impuestos", "zsh"), all.first().rows.map { it.window.window })
    }

    @Test fun `por cuenta, primero las cuentas y luego lo que no tiene`() {
        val groups = board.groups(AccountsQuery(grouping = AccountsQuery.Grouping.BY_ACCOUNT))
        assertEquals(
            listOf(
                AccountGroup.Key.Email("dev@notbetting.com", 3), AccountGroup.Key.Email("it@iberiavo.com", 2),
                AccountGroup.Key.Email("subs@iberiavo.com", 4), AccountGroup.Key.NoSession, AccountGroup.Key.Unread,
            ),
            groups.map { it.key },
        )
        // dev@notbetting.com está en dos hosts: este Mac y root@203.0.113.10.
        assertEquals(2, groups.first().rows.size)
        assertEquals(2, groups.first().hostCount)
        val withoutAgent = board.groups(AccountsQuery(grouping = AccountsQuery.Grouping.BY_ACCOUNT, showWithoutAgent = true))
        assertEquals(AccountGroup.Key.WithoutAgent, withoutAgent.last().key)
        assertEquals(listOf("zsh", "antigua"), withoutAgent.last().rows.map { it.window.window })
    }

    @Test fun `cada fila dice su cuenta, o por que no la tiene`() {
        assertEquals(AccountLabel.Email("dev@notbetting.com", 3), window("uniconnect").label)
        assertEquals(AccountLabel.Status(AccountStatus.NOT_READABLE, "root"), window("claudefix (root)").label)
        assertEquals(AccountLabel.Status(AccountStatus.NOT_EXPOSED, "dgomezm"), window("agy").label)
        assertEquals(AccountLabel.Status(AccountStatus.HOST_UNREACHABLE), window("iberiavochatbot").label)
        assertEquals(AccountLabel.Status(AccountStatus.SESSION_NOT_ALIVE), window("vieja").label)
        assertEquals(AccountLabel.Status(AccountStatus.NO_SESSION, "noleakos"), window("bot noleakos").label)
        assertEquals(AccountLabel.Status(AccountStatus.NO_AGENT), window("zsh").label)
        assertEquals(AccountLabel.Status(AccountStatus.NO_TMUX), window("antigua").label)
        // El nombre del equipo va delante del host.
        assertEquals("Mac · root@203.0.113.10:22", window("APP 2").hostLabel)
        assertEquals("Mac · Este Mac", window("uniconnect").hostLabel)
    }

    @Test fun `con clave de API se ensenya el metodo, no un email`() {
        val result = fixture("accounts-response.json").apply {
            getJSONArray("windows").getJSONObject(0).getJSONObject("account").put("method", "api_key").put("email", JSONObject.NULL)
        }
        val row = AccountsBoard(listOf(MachineAccounts("mac", "Mac", client.decodeAccounts(result)))).rows.first()
        assertEquals(AccountLabel.Method(AccountMethod.API_KEY), row.label)
        assertNull(row.email)
    }

    @Test fun `una Claude con token sale con el correo del token, o como token sin asociar`() {
        fun row(email: Any): AccountRow {
            val result = fixture("accounts-response.json").apply {
                getJSONArray("windows").getJSONObject(0).getJSONObject("account").put("method", "setup_token").put("email", email)
            }
            return AccountsBoard(listOf(MachineAccounts("mac", "Mac", client.decodeAccounts(result)))).rows.first()
        }
        val mapped = row("unixcision@gmail.com")
        assertEquals(AccountLabel.Email("unixcision@gmail.com", AccountPalette.indexOf("unixcision@gmail.com")), mapped.label)
        assertEquals("unixcision@gmail.com", mapped.email)
        val unmapped = row(JSONObject.NULL)
        assertEquals(AccountLabel.Method(AccountMethod.SETUP_TOKEN), unmapped.label)
        assertNull(unmapped.email)
    }

    @Test fun `un email solo cuenta si se leyo en esta llamada`() {
        // Un equipo que mandara un email junto a un estado que no es ok no lo convierte en la cuenta.
        val result = fixture("accounts-response.json").apply {
            getJSONArray("windows").getJSONObject(6).getJSONObject("account").put("email", "vieja@ejemplo.com")
        }
        val row = AccountsBoard(listOf(MachineAccounts("mac", "Mac", client.decodeAccounts(result)))).rows[6]
        assertEquals(AccountWindowState.NO_SESSION, row.state)
        assertNull(row.email)
        assertFalse(row.matches(AccountChip.Email("vieja@ejemplo.com")))
    }

    @Test fun `un estado nuevo del contrato va a sin leer y se ensenya tal cual`() {
        val result = fixture("accounts-response.json").apply {
            getJSONArray("windows").getJSONObject(0).put("state", "algo_del_futuro")
        }
        val row = AccountsBoard(listOf(MachineAccounts("mac", "Mac", client.decodeAccounts(result)))).rows.first()
        assertNull(row.state)
        assertTrue(row.unread)
        assertNull(row.email)
        assertEquals(AccountLabel.Unknown("algo_del_futuro"), row.label)
    }

    @Test fun `avisos por cada host que no se pudo leer y por cada equipo que no contesto`() {
        assertEquals(
            listOf(
                // La causa y la línea de SSH viajan con el aviso.
                AccountNotice.HostUnreadable(
                    "Mac · ec2-user@54.167.34.64:22", AccountHost.UNREACHABLE, "ssh_fallo", "ec2-user@54.167.34.64: Permission denied (publickey).",
                ),
                AccountNotice.HostUnreadable("Mac · root@198.51.100.7:22", AccountHost.VAULT_LOCKED, null, null),
            ),
            board.notices,
        )
        val failed = AccountsFailure(AccountsFailure.Kind.UNREACHABLE)
        val two = AccountsBoard(listOf(MachineAccounts("mac", "Mac", report), MachineAccounts("minipc", "MINIPC", null, failed)))
        assertEquals(AccountNotice.MachineFailed("MINIPC", failed), two.notices.first())
        // El equipo que no contestó no aporta ninguna fila.
        assertTrue(two.rows.none { it.machineID == "minipc" })
        assertEquals(board.rows.size, two.rows.size)
    }

    @Test fun `leido hace N s cuenta desde la respuesta y nunca en negativo`() {
        val checked = Instant.parse("2026-11-10T12:30:06Z").toEpochMilli()
        assertEquals(checked, board.checkedAtMillis)
        assertEquals(9L, board.ageSeconds(checked + 9_400))
        assertEquals(0L, board.ageSeconds(checked - 5_000))
        assertNull(AccountsBoard(emptyList()).ageSeconds(checked))
    }

    @Test fun `el color de una cuenta es el de la paleta del contrato`() {
        val palette = fixture("paleta.json")
        val colors = palette.getJSONArray("colores")
        assertEquals(colors.length(), AccountPalette.COLORS.size)
        for (index in 0 until colors.length()) {
            assertEquals(colors.getString(index), hex(AccountPalette.COLORS[index]))
        }
        assertEquals(palette.getString("neutro"), hex(AccountPalette.NEUTRAL))
        val examples = palette.getJSONObject("ejemplos")
        for (email in examples.keys()) {
            assertEquals(email, examples.getInt(email), AccountPalette.indexOf(email))
        }
        assertEquals(AccountPalette.NEUTRAL, AccountPalette.colorOf(null))
        assertEquals(AccountPalette.COLORS[3], AccountPalette.colorOf("Dev@NotBetting.com"))
    }

    @Test fun `el uso de cada ventana y de cada cuenta se lee del contrato`() {
        val usage = requireNotNull(report.windows.first().account?.usage)
        assertEquals("statusline", usage.source)
        assertEquals(Instant.parse("2026-11-10T12:29:58Z"), usage.observedAt)
        assertEquals(listOf("five_hour", "seven_day"), usage.limits.map { it.id })
        assertEquals(3.5, usage.limits[0].usedPercent, 0.0)
        assertEquals(300, usage.limits[0].windowMinutes)
        assertEquals(Instant.parse("2026-11-10T14:30:00Z"), usage.limits[0].resetsAt)
        assertNull(report.windows.single { it.window == "codex-antiresell" }.account?.usage)

        val raw = fixture("accounts-response.json").getJSONArray("accounts")
        assertEquals(List(raw.length()) { raw.getJSONObject(it).getString("key") }, report.accounts.map { it.key })
        val claude = report.accounts.first()
        assertEquals("claude", claude.provider)
        assertEquals(2, claude.windows)
        assertEquals(listOf("local", "ssh:root@203.0.113.10:22"), claude.hostKeys)
        assertEquals("local", claude.usage?.hostKey)
        assertEquals(4, claude.history.size)
        assertEquals(mapOf("seven_day" to 47.0, "five_hour" to 0.0), claude.history[2].limits)
        // Una cuenta sin dato de uso llega con `usage: null` y el histórico vacío.
        assertNull(report.accounts[1].usage)
        assertTrue(report.accounts[1].history.isEmpty())
    }

    @Test fun `uso por cuenta junta accounts y ventanas, con la formula comun`() {
        val accounts = board.usageAccounts
        // De más a menos ventanas: la de Claude, en dos, y luego las dos de Codex por email.
        assertEquals(report.accounts.map { it.key }, accounts.map { it.key })
        val claude = accounts.first()
        assertEquals("Mac · Este Mac", claude.seenOn)
        assertEquals(listOf("Mac · Este Mac", "Mac · root@203.0.113.10:22"), claude.hosts)
        assertEquals(listOf("uniconnect", "APP 2"), claude.rows.map { it.window.window })

        val zone = ZoneId.of("Europe/Madrid")
        val math = AccountUsageMath(Instant.parse("2026-11-10T12:30:06Z"), zone)
        val usage = requireNotNull(claude.usage)
        val week = usage.limits.single { it.id == "seven_day" }
        val fiveHours = usage.limits.single { it.id == "five_hour" }
        assertEquals(17.4549, requireNotNull(math.projection(week, usage.observedAt, claude.history)).perDay, 1e-3)
        // De las 5 horas solo hay una muestra dentro de su ventana: ni ritmo ni proyección.
        assertNull(math.projection(fiveHours, usage.observedAt, claude.history))
        assertFalse(math.isOld(requireNotNull(usage.observedAt)))
        // Pasado su reset, sale a 0 % y reseteado, aunque el dato dijera 3,5 %.
        assertEquals(AccountUsageMath.Reading(0.0, wasReset = true), AccountUsageMath(Instant.parse("2026-11-10T15:00:00Z"), zone).reading(fiveHours))

        val codex = accounts[2]
        val codexUsage = requireNotNull(codex.usage)
        assertEquals(LimitName.Week, LimitName.of(codexUsage.limits[0].id, codexUsage.limits[0].windowMinutes))
        // Codex preguntado en vivo: el dato es de esta misma lectura, no viejo.
        assertEquals("app_server", codexUsage.source)
        assertFalse(math.isOld(requireNotNull(codexUsage.observedAt)))
        assertEquals(ResetCredits(2, Instant.parse("2026-11-30T20:02:00Z")), codexUsage.resetCredits)
        // La cuenta de Claude no trae reseteos gratis.
        assertNull(usage.resetCredits)
        assertEquals(listOf("impuestos"), codex.rows.map { it.window.window })
        assertNull(accounts[1].usage)
    }

    private fun hex(argb: Long): String = "#%06X".format(argb and 0xFFFFFF)
}
