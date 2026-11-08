package com.unixcision.uniconnect.android.ui.design

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.ActivityState
import com.unixcision.uniconnect.android.domain.Elapsed
import com.unixcision.uniconnect.android.domain.Greeting
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/*
 * The words every design shares, so "Claude · Trabajando" or "Hace 2 min" read the same in all
 * four and live in one place.
 */

/** "Trabajando", "Te espera", "En reposo"; null when nothing is known. */
@Composable
fun activityText(state: ActivityState?): String? = when (state) {
    ActivityState.WORKING -> stringResource(R.string.activity_state_working)
    ActivityState.WAITING -> stringResource(R.string.activity_state_waiting)
    ActivityState.IDLE -> stringResource(R.string.activity_state_idle)
    ActivityState.UNKNOWN, null -> null
}

/** The line under a window's name: "Claude · Trabajando", "Claude", "Trabajando" or nothing. */
@Composable
fun windowLine(item: WindowItem): String? {
    val state = activityText(item.activity)
    return listOfNotNull(item.agent, state).joinToString(" · ").takeIf { it.isNotEmpty() }
}

/** "Ahora", "Hace 2 min", "Hace 3 h", "Hace 2 días"; null when the host did not say since when. */
@Composable
fun elapsedText(sinceEpochSeconds: Long?, nowEpochSeconds: Long): String? {
    val since = sinceEpochSeconds ?: return null
    return when (val elapsed = Elapsed.between(since, nowEpochSeconds)) {
        Elapsed.Now -> stringResource(R.string.elapsed_now)
        is Elapsed.Minutes -> pluralStringResource(R.plurals.elapsed_minutes, elapsed.count.toInt(), elapsed.count.toInt())
        is Elapsed.Hours -> pluralStringResource(R.plurals.elapsed_hours, elapsed.count.toInt(), elapsed.count.toInt())
        is Elapsed.Days -> pluralStringResource(R.plurals.elapsed_days, elapsed.count.toInt(), elapsed.count.toInt())
    }
}

/** "Buenos días", "Buenas tardes", "Buenas noches". */
@Composable
fun greetingText(greeting: Greeting): String = stringResource(
    when (greeting) {
        Greeting.MORNING -> R.string.home_greeting_morning
        Greeting.AFTERNOON -> R.string.home_greeting_afternoon
        Greeting.NIGHT -> R.string.home_greeting_night
    },
)

/** Today as a heading: "Domingo, 8 de noviembre". The product speaks Spanish only. */
@Composable
fun todayText(nowEpochSeconds: Long): String = remember(nowEpochSeconds / 3600) {
    SimpleDateFormat("EEEE, d 'de' MMMM", Locale.forLanguageTag("es-ES")).format(Date(nowEpochSeconds * 1000))
        .replaceFirstChar { it.uppercase() }
}
