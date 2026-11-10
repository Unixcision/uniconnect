package com.unixcision.uniconnect.android.domain

import java.time.Instant

/**
 * Un límite de uso tal y como lo dijo la propia IA (`accounts.v1` §2.4).
 *
 * [id] es `five_hour`, `seven_day`, `seven_day_opus`… en Claude, `primary` o `secondary` en Codex.
 * [usedPercent] es el porcentaje cuando se observó, no ahora: si [resetsAt] ya pasó, ver
 * [AccountUsageMath.reading].
 */
data class UsageLimit(val id: String, val usedPercent: Double, val resetsAt: Instant?, val windowMinutes: Int?)
