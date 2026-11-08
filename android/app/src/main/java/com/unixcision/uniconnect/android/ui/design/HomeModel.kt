package com.unixcision.uniconnect.android.ui.design

import androidx.compose.runtime.Immutable
import com.unixcision.uniconnect.android.domain.ActivityDigest
import com.unixcision.uniconnect.android.domain.Greeting
import com.unixcision.uniconnect.android.domain.HomeSummary
import com.unixcision.uniconnect.android.domain.Machine
import com.unixcision.uniconnect.android.domain.NoticeRoute
import com.unixcision.uniconnect.android.ui.MachineState

/**
 * Everything a design needs to draw the home, already worked out: the designs only decide how it
 * looks and where it goes, never what it says.
 */
@Immutable
data class HomeModel(
    val machines: List<HomeMachine>,
    /** Every machine added up: connected out of saved, windows, AIs working and waiting. */
    val total: HomeSummary,
    /** Who waits, who works and what changed lately, over every machine. */
    val activity: ActivityDigest,
    val greeting: Greeting,
    /** Now, for "hace 2 min": designs never read the clock themselves. */
    val nowEpochSeconds: Long,
    val refreshing: Boolean,
    /** Several connection failures in a row or a crash report: the diagnostics deserve a mark. */
    val troubled: Boolean,
)

/** One saved machine on the home: who it is, whether it answers and what its AIs are doing. */
@Immutable
data class HomeMachine(val machine: Machine, val state: MachineState, val summary: HomeSummary)

/** What the home can do; every design wires the same actions. */
@Immutable
class HomeActions(
    val onMenu: () -> Unit,
    val onRefresh: () -> Unit,
    val onDiagnostics: () -> Unit,
    val onAdd: () -> Unit,
    val onSelectMachine: (machineID: String) -> Unit,
    /** Opens one window straight away: the reply to "APP 2 te espera". */
    val onOpenWindow: (NoticeRoute) -> Unit,
    val onFiles: () -> Unit,
    val onHistory: () -> Unit,
    val onNotices: () -> Unit,
    val onSettings: () -> Unit,
)
