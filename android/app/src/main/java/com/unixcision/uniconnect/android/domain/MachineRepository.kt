package com.unixcision.uniconnect.android.domain

import kotlinx.coroutines.flow.Flow

interface MachineRepository {
    val machines: Flow<List<Machine>>
    suspend fun save(machine: Machine)
    suspend fun remove(id: String)
}
