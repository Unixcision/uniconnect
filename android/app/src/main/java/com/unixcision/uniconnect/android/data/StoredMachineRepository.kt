package com.unixcision.uniconnect.android.data

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import com.unixcision.uniconnect.android.domain.Machine
import com.unixcision.uniconnect.android.domain.MachineEndpoint
import com.unixcision.uniconnect.android.domain.MachineRepository
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.distinctUntilChanged
import org.json.JSONArray
import org.json.JSONObject

/** Atomic DataStore mutations keep local configuration durable without storing credentials. */
class StoredMachineRepository(private val store: DataStore<Preferences>) : MachineRepository {
    private val key = stringPreferencesKey("machines.v1")
    override val machines = store.data.map { decode(it[key]) }.distinctUntilChanged()

    override suspend fun save(machine: Machine) {
        store.edit { preferences ->
            val previous = decode(preferences[key])
            require(previous.none { it.id != machine.id && it.endpoint == machine.endpoint })
            preferences[key] = encode(previous.filterNot { it.id == machine.id } + machine)
        }
    }

    override suspend fun remove(id: String) {
        store.edit { preferences -> preferences[key] = encode(decode(preferences[key]).filterNot { it.id == id }) }
    }

    private fun decode(raw: String?): List<Machine> {
        if (raw == null) return emptyList()
        val array = JSONArray(raw)
        return List(array.length()) { index ->
            val item = array.getJSONObject(index)
            val endpoint = requireNotNull(MachineEndpoint.parse(item.getString("host"), item.getInt("port").toString()))
            Machine(item.getString("id"), item.getString("name"), endpoint)
        }.also { machines -> require(machines.map { it.id }.distinct().size == machines.size) }
    }

    private fun encode(machines: List<Machine>): String = JSONArray().apply {
        machines.forEach { machine ->
            put(JSONObject().put("id", machine.id).put("name", machine.name)
                .put("host", machine.endpoint.host).put("port", machine.endpoint.port))
        }
    }.toString()
}
