package com.unixcision.uniconnect.android.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.CardGiftcard
import androidx.compose.material.icons.rounded.RestartAlt
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SecondaryScrollableTabRow
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringArrayResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.AccountPalette
import com.unixcision.uniconnect.android.domain.AccountUsage
import com.unixcision.uniconnect.android.domain.AccountUsageMath
import com.unixcision.uniconnect.android.domain.AccountsBoard
import com.unixcision.uniconnect.android.domain.CodexResetStep
import com.unixcision.uniconnect.android.domain.CodexResetTarget
import com.unixcision.uniconnect.android.domain.ResetCredits
import com.unixcision.uniconnect.android.domain.LimitName
import com.unixcision.uniconnect.android.domain.UsageAccount
import com.unixcision.uniconnect.android.domain.UsageChart
import com.unixcision.uniconnect.android.domain.UsageLimit
import com.unixcision.uniconnect.android.ui.components.GlassCard
import com.unixcision.uniconnect.android.ui.theme.UniTheme
import java.time.Instant
import java.time.ZoneId
import java.util.Locale
import kotlin.math.roundToInt
import kotlin.math.roundToLong

/**
 * «Uso por cuenta» (`accounts.v1` §4.1): pestañas desplazables con «Resumen» y una por cuenta, y
 * el contenido de la elegida.
 *
 * Todo lo que depende de la hora sale de [math], creado con la hora de la pantalla: aquí nada mira
 * el reloj.
 */
internal fun LazyListScope.usageItems(
    board: AccountsBoard,
    selectedKey: String?,
    math: AccountUsageMath,
    now: Instant,
    zone: ZoneId,
    onSelect: (String?) -> Unit,
    onOpenWindow: (machineID: String, workspaceID: String, windowID: String) -> Unit,
    onShowWindows: (String) -> Unit,
    resetTarget: (UsageAccount) -> CodexResetTarget? = { null },
    reset: CodexResetStep = CodexResetStep.Idle,
    onAskReset: (CodexResetTarget) -> Unit = {},
) {
    val accounts = board.usageAccounts
    if (accounts.isEmpty()) {
        item { UsageEmpty(stringResource(R.string.usage_no_accounts)) }
        return
    }
    val selected = accounts.firstOrNull { it.key == selectedKey }
    item { AccountTabs(accounts, selected, math, onSelect) }
    if (selected == null) {
        item { Text(stringResource(R.string.usage_summary_title), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold) }
        accounts.chunked(2).forEach { pair ->
            item {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(UniTheme.spacing.gap)) {
                    pair.forEach { account -> SummaryCard(account, math, Modifier.weight(1f)) { onSelect(account.key) } }
                    if (pair.size == 1) Spacer(Modifier.weight(1f))
                }
            }
        }
        return
    }
    item { DetailHeader(selected) }
    selected.usage?.resetCredits?.takeIf { it.available > 0 }?.let { credits ->
        item {
            CreditsCard(
                credits, math, resetTarget(selected),
                busy = reset is CodexResetStep.Running,
                running = reset is CodexResetStep.Running && reset.target.accountKey == selected.key,
                onAskReset = onAskReset,
            )
        }
    }
    val usage = selected.usage
    if (usage == null || usage.limits.isEmpty()) {
        item { NoUsageCard(selected) }
    } else {
        usage.limits.forEach { limit -> item { LimitCard(selected, usage, limit, math) } }
    }
    item { ChartCard(selected, now, zone) }
    item { WhereCard(selected, onOpenWindow, onShowWindows) }
}

/** «Resumen» y una pestaña por cuenta, con su color y un mini-anillo del límite más alto. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AccountTabs(accounts: List<UsageAccount>, selected: UsageAccount?, math: AccountUsageMath, onSelect: (String?) -> Unit) {
    val index = selected?.let { accounts.indexOf(it) + 1 } ?: 0
    SecondaryScrollableTabRow(
        selectedTabIndex = index, edgePadding = 0.dp, containerColor = Color.Transparent,
        contentColor = UniTheme.colors.accent, divider = { HorizontalDivider(color = UniTheme.colors.outline) },
    ) {
        Tab(selected = index == 0, onClick = { onSelect(null) }, unselectedContentColor = UniTheme.colors.muted) {
            Text(stringResource(R.string.usage_summary), Modifier.padding(horizontal = 12.dp, vertical = 12.dp), maxLines = 1)
        }
        accounts.forEachIndexed { position, account ->
            Tab(selected = index == position + 1, onClick = { onSelect(account.key) }, unselectedContentColor = UniTheme.colors.muted) {
                Row(Modifier.padding(horizontal = 12.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    UsageRing(highest(account, math), toneOf(account), 20.dp, 3.dp)
                    Text(account.email ?: account.displayName, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
}

/** Una cuenta en la rejilla de «Resumen»: su anillo más alto, cada límite y lo fresco que es el dato. */
@Composable
private fun SummaryCard(account: UsageAccount, math: AccountUsageMath, modifier: Modifier, onClick: () -> Unit) {
    val tone = toneOf(account)
    GlassCard(modifier, onClick = onClick) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(
                account.email ?: account.displayName, style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold,
                color = tone, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
            Text(
                listOfNotNull(account.displayName, account.plan).joinToString(" · "),
                style = MaterialTheme.typography.labelSmall, color = UniTheme.colors.muted, maxLines = 1,
            )
            account.usage?.resetCredits?.takeIf { it.available > 0 }?.let { credits ->
                GiftBadge(pluralStringResource(R.plurals.usage_credits_badge, credits.available, credits.available))
            }
            val usage = account.usage
            if (usage == null || usage.limits.isEmpty()) {
                Text(noUsageText(account), style = MaterialTheme.typography.labelSmall, color = UniTheme.colors.muted, maxLines = 4, overflow = TextOverflow.Ellipsis)
            } else {
                val top = highest(account, math) ?: 0.0
                Box(Modifier.fillMaxWidth().padding(vertical = 4.dp), contentAlignment = Alignment.Center) {
                    UsageRing(top, ringTone(tone, top), 76.dp, 8.dp) {
                        Text(percentText(top), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
                    }
                }
                usage.limits.forEach { limit ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(limitText(LimitName.of(limit.id, limit.windowMinutes)), Modifier.weight(1f), style = MaterialTheme.typography.labelSmall, maxLines = 1)
                        Text(percentText(math.reading(limit).percent), style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.SemiBold)
                    }
                }
                usage.observedAt?.let { seen ->
                    Text(
                        stringResource(R.string.usage_seen_nowhere, ageText(math.age(seen))), style = MaterialTheme.typography.labelSmall,
                        color = if (math.isOld(seen)) UniTheme.colors.warning else UniTheme.colors.muted, maxLines = 1,
                    )
                }
            }
        }
    }
}

/** El email en su color, el proveedor, el plan y «En N ventanas · M hosts». */
@Composable
private fun DetailHeader(account: UsageAccount) {
    Column(Modifier.fillMaxWidth().padding(top = 4.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            account.email ?: account.displayName, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold,
            color = toneOf(account), maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Pill(account.displayName, UniTheme.colors.muted)
            account.plan?.let { Pill(it, UniTheme.colors.accent) }
            Text(
                "${pluralStringResource(R.plurals.usage_in_windows, account.windows, account.windows)} · " +
                    pluralStringResource(R.plurals.usage_hosts, account.hosts.size, account.hosts.size),
                style = MaterialTheme.typography.labelMedium, color = UniTheme.colors.muted, maxLines = 1,
            )
        }
    }
}

/** Un límite: anillo con el porcentaje, cuándo resetea, de cuándo es el dato, ritmo y proyección. */
@Composable
private fun LimitCard(account: UsageAccount, usage: AccountUsage, limit: UsageLimit, math: AccountUsageMath) {
    val reading = math.reading(limit)
    val tone = toneOf(account)
    GlassCard(Modifier.fillMaxWidth()) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            UsageRing(reading.percent, ringTone(tone, reading.percent), 88.dp, 9.dp) {
                Text(percentText(reading.percent), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
            }
            Spacer(Modifier.width(16.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(limitText(LimitName.of(limit.id, limit.windowMinutes)), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
                limit.resetsAt?.let { resetsAt ->
                    Text(
                        if (reading.wasReset) stringResource(R.string.usage_was_reset, weekdayTime(math, resetsAt))
                        else stringResource(R.string.usage_resets_in, spanText(math.remaining(resetsAt)), weekdayTime(math, resetsAt)),
                        style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.muted,
                    )
                }
                usage.observedAt?.let { seen ->
                    // Un dato de hace más de una hora se dice en ámbar: puede que ya no sea así.
                    Text(
                        account.seenOn?.let { stringResource(R.string.usage_seen, ageText(math.age(seen)), it) }
                            ?: stringResource(R.string.usage_seen_nowhere, ageText(math.age(seen))),
                        style = MaterialTheme.typography.bodySmall,
                        color = if (math.isOld(seen)) UniTheme.colors.warning else UniTheme.colors.muted,
                    )
                }
                math.projection(limit, usage.observedAt, account.history)?.let { projection ->
                    Text(
                        stringResource(R.string.usage_rate, String.format(SPANISH, "%.1f", projection.perDay)),
                        style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.text,
                    )
                    val exhaustion = projection.exhaustion
                    Text(
                        if (exhaustion != null) stringResource(R.string.usage_exhaustion, weekdayTime(math, exhaustion))
                        else stringResource(R.string.usage_projection, maxOf(0.0, projection.atReset).roundToInt()),
                        style = MaterialTheme.typography.bodySmall,
                        color = if (exhaustion != null) UniTheme.colors.warning else UniTheme.colors.muted,
                    )
                }
            }
        }
    }
}

/**
 * Los reseteos gratis de Codex de la cuenta y, si el equipo sabe gastarlos, «Usar un reseteo gratis».
 * Mientras uno va, el botón queda deshabilitado; el de esta cuenta, con su indicador.
 */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun CreditsCard(
    credits: ResetCredits,
    math: AccountUsageMath,
    target: CodexResetTarget?,
    busy: Boolean,
    running: Boolean,
    onAskReset: (CodexResetTarget) -> Unit,
) {
    GlassCard(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Rounded.CardGiftcard, null, Modifier.size(22.dp), tint = UniTheme.colors.success)
                Spacer(Modifier.width(12.dp))
                val expires = credits.nextExpiresAt
                Text(
                    if (expires != null) pluralStringResource(R.plurals.usage_credits, credits.available, credits.available, dayMonth(math, expires))
                    else pluralStringResource(R.plurals.usage_credits_no_date, credits.available, credits.available),
                    Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium,
                )
            }
            if (target != null) {
                FilledTonalButton(onClick = { onAskReset(target) }, enabled = !busy) {
                    if (running) LoadingIndicator(Modifier.size(18.dp), color = UniTheme.colors.accent)
                    else Icon(Icons.Rounded.RestartAlt, null, Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.reset_button))
                }
            }
        }
    }
}

@Composable
private fun GiftBadge(text: String) {
    Row(
        Modifier.background(UniTheme.colors.success.copy(alpha = .14f), UniTheme.shapes.chip).padding(horizontal = 8.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Icon(Icons.Rounded.CardGiftcard, null, Modifier.size(12.dp), tint = UniTheme.colors.success)
        Text(text, style = MaterialTheme.typography.labelSmall, color = UniTheme.colors.success, fontWeight = FontWeight.Bold, maxLines = 1)
    }
}

/** «30 nov», en la hora local. */
@Composable
private fun dayMonth(math: AccountUsageMath, instant: Instant): String {
    val local = math.local(instant)
    val months = stringArrayResource(R.array.usage_months_short)
    return stringResource(R.string.usage_day_month, local.dayOfMonth, months[local.monthValue - 1])
}

@Composable
private fun NoUsageCard(account: UsageAccount) {
    GlassCard(Modifier.fillMaxWidth()) {
        Text(noUsageText(account), Modifier.padding(16.dp), style = MaterialTheme.typography.bodyMedium, color = UniTheme.colors.muted)
    }
}

/** Los 7 días del histórico: una línea por límite, de 0 a 100 %, con los resets marcados. */
@Composable
private fun ChartCard(account: UsageAccount, now: Instant, zone: ZoneId) {
    val chart = remember(account, now) { UsageChart.of(account, now) }
    val tones = chart.series.indices.map { seriesTone(account, it) }
    val measurer = rememberTextMeasurer()
    val labelStyle = MaterialTheme.typography.labelSmall.copy(color = UniTheme.colors.muted)
    val grid = UniTheme.colors.outline
    val resetTone = UniTheme.colors.warning
    val weekdays = stringArrayResource(R.array.usage_weekdays_short)
    // Las medianoches locales de la semana, con el día que empieza en cada una.
    val days = remember(chart.start, chart.end, zone) {
        var day = chart.start.atZone(zone).toLocalDate().plusDays(1)
        buildList {
            while (true) {
                val midnight = day.atStartOfDay(zone).toInstant()
                if (midnight.isAfter(chart.end)) break
                add(midnight to day.dayOfWeek.value)
                day = day.plusDays(1)
            }
        }
    }
    GlassCard(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(stringResource(R.string.usage_chart_title), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
            if (chart.isEmpty) {
                Text(stringResource(R.string.usage_chart_empty), style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.muted)
            } else {
                Canvas(Modifier.fillMaxWidth().height(190.dp)) {
                    val left = 36.dp.toPx()
                    val right = 6.dp.toPx()
                    val top = 8.dp.toPx()
                    val bottom = 20.dp.toPx()
                    val width = size.width - left - right
                    val height = size.height - top - bottom
                    val startMillis = chart.start.toEpochMilli()
                    val spanMillis = (chart.end.toEpochMilli() - startMillis).coerceAtLeast(1).toFloat()
                    fun x(at: Instant) = left + width * ((at.toEpochMilli() - startMillis) / spanMillis)
                    fun y(percent: Double) = top + height * (1f - (percent.coerceIn(0.0, 100.0) / 100.0).toFloat())
                    for (step in listOf(0, 25, 50, 75, 100)) {
                        drawLine(grid.copy(alpha = if (step % 50 == 0) .9f else .35f), Offset(left, y(step.toDouble())), Offset(left + width, y(step.toDouble())), 1.dp.toPx())
                    }
                    for (step in listOf(0, 50, 100)) {
                        val layout = measurer.measure("$step %", labelStyle)
                        drawText(layout, topLeft = Offset(left - layout.size.width - 6.dp.toPx(), y(step.toDouble()) - layout.size.height / 2f))
                    }
                    days.forEach { (midnight, weekday) ->
                        val at = x(midnight)
                        drawLine(grid.copy(alpha = .35f), Offset(at, top), Offset(at, top + height), 1.dp.toPx())
                        val layout = measurer.measure(weekdays[weekday - 1], labelStyle)
                        drawText(layout, topLeft = Offset(at + 3.dp.toPx(), top + height + 3.dp.toPx()))
                    }
                    chart.resets.forEach { reset ->
                        drawLine(
                            resetTone.copy(alpha = .8f), Offset(x(reset), top), Offset(x(reset), top + height), 1.5.dp.toPx(),
                            pathEffect = PathEffect.dashPathEffect(floatArrayOf(6.dp.toPx(), 4.dp.toPx())),
                        )
                    }
                    chart.series.forEachIndexed { index, series ->
                        val tone = tones[index]
                        if (series.points.size > 1) {
                            val path = Path()
                            series.points.forEachIndexed { position, (at, percent) ->
                                if (position == 0) path.moveTo(x(at), y(percent)) else path.lineTo(x(at), y(percent))
                            }
                            drawPath(path, tone, style = Stroke(2.5.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
                        }
                        series.points.forEach { (at, percent) -> drawCircle(tone, 3.dp.toPx(), Offset(x(at), y(percent))) }
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
                    chart.series.forEachIndexed { index, series ->
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            Box(Modifier.size(8.dp).background(tones[index], CircleShape))
                            Text(limitText(series.name), style = MaterialTheme.typography.labelSmall, color = UniTheme.colors.muted)
                        }
                    }
                    if (chart.resets.isNotEmpty()) {
                        Text("┆ ${stringResource(R.string.usage_chart_reset)}", style = MaterialTheme.typography.labelSmall, color = resetTone)
                    }
                }
            }
        }
    }
}

/** Los hosts y ventanas que usan la cuenta; tocar una lleva a ella. */
@Composable
private fun WhereCard(
    account: UsageAccount,
    onOpenWindow: (machineID: String, workspaceID: String, windowID: String) -> Unit,
    onShowWindows: (String) -> Unit,
) {
    GlassCard(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(start = 16.dp, end = 8.dp, top = 12.dp, bottom = 12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.usage_where), Modifier.weight(1f), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
                account.email?.let { email ->
                    TextButton(onClick = { onShowWindows(email) }) { Text(stringResource(R.string.usage_show_windows)) }
                }
            }
            val byHost = account.rows.groupBy { it.hostLabel }
            // Sin ventanas en esta pasada (o de un equipo que no contestó), al menos los hosts que dio.
            if (byHost.isEmpty()) account.hosts.forEach { host ->
                Text(host, style = MaterialTheme.typography.labelMedium, color = UniTheme.colors.muted)
            }
            byHost.forEach { (host, rows) ->
                Text(host, Modifier.padding(top = 6.dp), style = MaterialTheme.typography.labelMedium, color = UniTheme.colors.muted)
                rows.forEach { row ->
                    Row(
                        Modifier.fillMaxWidth().clickable { onOpenWindow(row.machineID, row.window.workspaceID, row.window.terminalID) }.padding(vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text(row.window.window, style = MaterialTheme.typography.bodyMedium, fontFamily = UniTheme.type.identifierFamily, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(row.window.workspace, style = MaterialTheme.typography.labelSmall, color = UniTheme.colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                        Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = UniTheme.colors.muted)
                    }
                }
            }
        }
    }
}

/** Un anillo de 0 a 100 % con [content] en el centro. */
@Composable
private fun UsageRing(percent: Double?, tone: Color, size: Dp, stroke: Dp, content: @Composable () -> Unit = {}) {
    val track = UniTheme.colors.outline
    Box(Modifier.size(size), contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize()) {
            val width = stroke.toPx()
            val arc = Size(this.size.width - width, this.size.height - width)
            val corner = Offset(width / 2, width / 2)
            drawArc(track, 0f, 360f, useCenter = false, topLeft = corner, size = arc, style = Stroke(width))
            val sweep = ((percent ?: 0.0).coerceIn(0.0, 100.0) / 100.0 * 360.0).toFloat()
            if (sweep > 0f) drawArc(tone, -90f, sweep, useCenter = false, topLeft = corner, size = arc, style = Stroke(width, cap = StrokeCap.Round))
        }
        content()
    }
}

@Composable
private fun Pill(text: String, color: Color) {
    Text(
        text, Modifier.background(color.copy(alpha = .14f), UniTheme.shapes.chip).padding(horizontal = 8.dp, vertical = 3.dp),
        style = MaterialTheme.typography.labelSmall, color = color, fontWeight = FontWeight.Bold, maxLines = 1,
    )
}

@Composable
private fun UsageEmpty(text: String) {
    Text(text, Modifier.fillMaxWidth().padding(vertical = 32.dp), style = MaterialTheme.typography.bodyMedium, color = UniTheme.colors.muted)
}

/** El porcentaje del límite más alto ahora, o nulo sin uso. */
private fun highest(account: UsageAccount, math: AccountUsageMath): Double? =
    account.usage?.limits?.maxOfOrNull { math.reading(it).percent }

/** El color de la cuenta, o el neutro sin email. */
private fun toneOf(account: UsageAccount): Color = Color(AccountPalette.colorOf(account.email))

/** El anillo en el color de la cuenta, salvo cerca del límite. */
@Composable
private fun ringTone(tone: Color, percent: Double): Color = if (percent >= DANGER_PERCENT) UniTheme.colors.danger else tone

/** La línea de cada límite: la primera en el color de la cuenta, las demás en otros de la paleta. */
private fun seriesTone(account: UsageAccount, index: Int): Color {
    val base = account.colorIndex ?: return Color(if (index == 0) AccountPalette.NEUTRAL else AccountPalette.COLORS[index % AccountPalette.COLORS.size])
    return Color(AccountPalette.COLORS[(base + index * 3) % AccountPalette.COLORS.size])
}

@Composable
private fun limitText(name: LimitName): String = when (name) {
    LimitName.FiveHours -> stringResource(R.string.usage_limit_five_hours)
    LimitName.Week -> stringResource(R.string.usage_limit_week)
    LimitName.WeekOpus -> stringResource(R.string.usage_limit_week_opus)
    LimitName.WeekSonnet -> stringResource(R.string.usage_limit_week_sonnet)
    LimitName.WeekFable -> stringResource(R.string.usage_limit_week_fable)
    is LimitName.Hours -> stringResource(R.string.usage_limit_hours, name.hours)
    is LimitName.Raw -> name.id
}

@Composable
private fun noUsageText(account: UsageAccount): String = when (account.provider) {
    "claude" -> stringResource(R.string.usage_none_claude)
    "codex" -> stringResource(R.string.usage_none_codex)
    else -> stringResource(R.string.usage_none_other)
}

/** «sáb 15:00», en la hora local. */
@Composable
private fun weekdayTime(math: AccountUsageMath, instant: Instant): String {
    val local = math.local(instant)
    val weekdays = stringArrayResource(R.array.usage_weekdays_short)
    return stringResource(R.string.usage_weekday_time, weekdays[local.dayOfWeek.value - 1], local.hour, local.minute)
}

/** «2 d 3 h», «3 h 20 min» o «12 min». */
@Composable
private fun spanText(span: AccountUsageMath.Span): String = when {
    span.days > 0 -> stringResource(R.string.usage_span_days_hours, span.days.toInt(), span.hours.toInt())
    span.hours > 0 -> stringResource(R.string.usage_span_hours_minutes, span.hours.toInt(), span.minutes.toInt())
    else -> stringResource(R.string.usage_span_minutes, span.minutes.toInt())
}

/** «hace 12 s», «hace 4 min», «hace 3 h», «hace 2 d». */
@Composable
private fun ageText(age: AccountUsageMath.Age): String = when (age.unit) {
    AccountUsageMath.Age.Unit.SECONDS -> stringResource(R.string.usage_age_seconds, age.value.toInt())
    AccountUsageMath.Age.Unit.MINUTES -> stringResource(R.string.usage_age_minutes, age.value.toInt())
    AccountUsageMath.Age.Unit.HOURS -> stringResource(R.string.usage_age_hours, age.value.toInt())
    AccountUsageMath.Age.Unit.DAYS -> stringResource(R.string.usage_age_days, age.value.toInt())
}

/** «51 %» o «3,5 %»: un decimal solo cuando lo hay. */
private fun percentText(percent: Double): String {
    val rounded = (percent * 10).roundToLong() / 10.0
    return if (rounded % 1.0 == 0.0) "${rounded.toLong()} %" else String.format(SPANISH, "%.1f %%", rounded)
}

private val SPANISH: Locale = Locale.forLanguageTag("es-ES")

/** A partir de aquí el anillo avisa en rojo. */
private const val DANGER_PERCENT = 90.0
