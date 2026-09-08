package com.unixcision.uniconnect.android.domain

/** Durable storage of ``BoxOverrides`` per machine; nothing here reaches the host. */
interface BoxOverridesRepository {
    suspend fun load(machineID: String): BoxOverrides
    suspend fun save(machineID: String, overrides: BoxOverrides)
}
