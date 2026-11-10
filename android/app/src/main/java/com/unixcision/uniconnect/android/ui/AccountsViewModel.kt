package com.unixcision.uniconnect.android.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.unixcision.uniconnect.android.domain.AccountChip
import com.unixcision.uniconnect.android.domain.AccountsBoard
import com.unixcision.uniconnect.android.domain.AccountsFailure
import com.unixcision.uniconnect.android.domain.AccountsQuery
import com.unixcision.uniconnect.android.domain.AccountsReport
import com.unixcision.uniconnect.android.domain.Machine
import com.unixcision.uniconnect.android.domain.MachineAccounts
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import java.util.concurrent.atomic.AtomicInteger

/**
 * «Cuentas de IA» (`accounts.v1`): con qué cuenta está cada IA de cada equipo, leído en vivo.
 *
 * La regla que manda es la frescura. Cada [refresh] pregunta a todos los equipos a la vez y
 * sustituye la lectura entera: un equipo que falla se queda sin filas y con su aviso, nunca con lo
 * que dijo la vez anterior. Al salir de la pantalla ([stop]) se olvida todo, así que al volver no se
 * pinta nada viejo mientras llega lo nuevo. Quien llama decide el ritmo: la pantalla relee cada 15 s
 * solo mientras está a la vista.
 *
 * [read] es la llamada a un equipo; [scope] solo se pasa en las pruebas.
 */
class AccountsViewModel(
    private val read: suspend (Machine) -> AccountsReport,
    scope: CoroutineScope? = null,
) : ViewModel() {
    /**
     * @property board la última pasada completa, o nula si todavía no ha terminado ninguna.
     * @property reading hay una pasada en marcha.
     */
    data class State(
        val board: AccountsBoard? = null,
        val reading: Boolean = false,
        val query: AccountsQuery = AccountsQuery(),
    )

    private val work: CoroutineScope by lazy { scope ?: viewModelScope }
    private val mutableState = MutableStateFlow(State())
    val state = mutableState.asStateFlow()

    /** La pasada en marcha; otra petición mientras tanto espera a esta y comparte su resultado. */
    @Volatile private var current: Deferred<Unit>? = null

    /**
     * Cuántas veces se ha salido de la pantalla. Una pasada que termina en otro hilo justo después
     * de [stop] no puede volver a pintar lo que se acaba de olvidar.
     */
    private val generation = AtomicInteger()

    /**
     * Lee ahora las cuentas de [machines] y vuelve cuando la pasada termina.
     *
     * Si ya hay una en marcha no se encola otra: se espera a esa, como pide el contrato.
     */
    suspend fun refresh(machines: List<Machine>) {
        current?.takeIf { it.isActive }?.let { return it.await() }
        // Perezosa: queda apuntada como la pasada en curso antes de empezar a leer.
        val pass = work.async(Dispatchers.IO, start = CoroutineStart.LAZY) { readAll(machines) }
        current = pass
        pass.await()
    }

    /** Deja de leer y olvida la lectura: la pantalla ya no está a la vista. */
    fun stop() {
        generation.incrementAndGet()
        current?.cancel()
        current = null
        mutableState.update { it.copy(board = null, reading = false) }
    }

    fun choose(chip: AccountChip) = mutableState.update { it.copy(query = it.query.copy(chip = chip)) }

    fun search(text: String) = mutableState.update { it.copy(query = it.query.copy(search = text)) }

    fun group(grouping: AccountsQuery.Grouping) = mutableState.update { it.copy(query = it.query.copy(grouping = grouping)) }

    fun showWithoutAgent(show: Boolean) = mutableState.update { it.copy(query = it.query.copy(showWithoutAgent = show)) }

    private suspend fun readAll(machines: List<Machine>) {
        val mine = generation.get()
        mutableState.update { it.copy(reading = true) }
        try {
            val pass = coroutineScope { machines.map { machine -> async { readOne(machine) } }.awaitAll() }
            if (generation.get() == mine) mutableState.update { it.copy(board = AccountsBoard(pass), reading = false) }
        } finally {
            if (generation.get() == mine) mutableState.update { it.copy(reading = false) }
        }
    }

    private suspend fun readOne(machine: Machine): MachineAccounts = try {
        MachineAccounts(machine.id, machine.name, read(machine))
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (failure: Exception) {
        MachineAccounts(machine.id, machine.name, report = null, failure = AccountsFailure.of(failure))
    }
}
