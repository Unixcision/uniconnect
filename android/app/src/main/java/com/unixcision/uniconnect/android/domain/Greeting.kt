package com.unixcision.uniconnect.android.domain

/** The home's greeting, by the hour of the day on the phone. */
enum class Greeting {
    MORNING, AFTERNOON, NIGHT;

    companion object {
        /** From six in the morning to two in the afternoon, then until nine at night, then night. */
        fun at(hour: Int): Greeting = when (hour) {
            in 6..13 -> MORNING
            in 14..20 -> AFTERNOON
            else -> NIGHT
        }
    }
}
