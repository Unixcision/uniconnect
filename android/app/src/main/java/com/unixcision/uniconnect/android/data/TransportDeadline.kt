package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.MachineFailure

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withTimeout

/** A network deadline is an ordinary failure; only cancellation by the owner cancels its workflow. */
internal suspend fun <T> transportDeadline(milliseconds: Long, operation: suspend CoroutineScope.() -> T): T = try {
    withTimeout(milliseconds, operation)
} catch (timeout: TimeoutCancellationException) {
    currentCoroutineContext().ensureActive()
    throw MachineFailure.DeadlineExceeded()
}
