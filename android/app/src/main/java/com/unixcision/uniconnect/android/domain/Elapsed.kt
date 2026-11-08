package com.unixcision.uniconnect.android.domain

/** How long ago something happened, rounded the way a person says it: now, minutes, hours, days. */
sealed interface Elapsed {
    data object Now : Elapsed
    data class Minutes(val count: Long) : Elapsed
    data class Hours(val count: Long) : Elapsed
    data class Days(val count: Long) : Elapsed

    companion object {
        /** From [sinceEpochSeconds] to [nowEpochSeconds]; a time in the future (clock skew) is now. */
        fun between(sinceEpochSeconds: Long, nowEpochSeconds: Long): Elapsed {
            val seconds = (nowEpochSeconds - sinceEpochSeconds).coerceAtLeast(0)
            return when {
                seconds < 60 -> Now
                seconds < 60 * 60 -> Minutes(seconds / 60)
                seconds < 24 * 60 * 60 -> Hours(seconds / (60 * 60))
                else -> Days(seconds / (24 * 60 * 60))
            }
        }
    }
}
