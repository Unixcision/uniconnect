package com.unixcision.uniconnect.android.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.unixcision.uniconnect.android.data.InboxPreviewCache
import com.unixcision.uniconnect.android.domain.InboxClient
import com.unixcision.uniconnect.android.domain.InboxDeletion
import com.unixcision.uniconnect.android.domain.InboxDeletionResult
import com.unixcision.uniconnect.android.domain.InboxEntry
import com.unixcision.uniconnect.android.domain.InboxListing
import com.unixcision.uniconnect.android.domain.Machine
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import java.io.File

/**
 * La bandeja de entrada de cada equipo vista desde el móvil (`inbox.v1`): qué hay y cuánto ocupa,
 * las copias locales para la vista previa, y el borrado con criterio, siempre simulado antes.
 *
 * Una sola fuente para las dos pantallas que la usan, la galería del clip y el medidor de
 * Ajustes: lo que se borra en una desaparece de la otra sin volver a preguntar.
 *
 * [scope] solo se pasa en los tests; la app usa el del ViewModel.
 */
class InboxViewModel(
    private val client: InboxClient,
    private val previews: InboxPreviewCache,
    scope: CoroutineScope? = null,
) : ViewModel() {
    /** Lo último que se sabe de la bandeja de un equipo. */
    data class MachineInbox(
        val loading: Boolean = false,
        val listing: InboxListing? = null,
        val failure: Throwable? = null,
        /** Cuántas entradas se piden: crece con «Ver más». */
        val limit: Int = PAGE,
    )

    /** La copia local de un archivo del equipo: bajando (con lo que lleva), lista o fallida. */
    data class Preview(val received: Long = 0, val file: File? = null, val failure: Throwable? = null)

    /** Lo que borraría [deletion], calculado por el equipo sin tocar nada. */
    data class Estimate(val deletion: InboxDeletion, val result: InboxDeletionResult? = null, val failure: Throwable? = null)

    /** Un borrado de verdad: en marcha, hecho (con lo liberado) o fallido. */
    data class Removal(val running: Boolean = true, val result: InboxDeletionResult? = null, val failure: Throwable? = null)

    data class State(
        val inboxes: Map<String, MachineInbox> = emptyMap(),
        val previews: Map<String, Preview> = emptyMap(),
        val estimates: Map<String, Estimate> = emptyMap(),
        val removals: Map<String, Removal> = emptyMap(),
    )

    private val work: CoroutineScope by lazy { scope ?: viewModelScope }
    private val mutableState = MutableStateFlow(State())
    val state = mutableState.asStateFlow()
    private val listings = mutableMapOf<String, Job>()
    private val estimating = mutableMapOf<String, Job>()
    // Dos descargas a la vez: la galería pide varias miniaturas de golpe y el enlace es del móvil.
    private val downloads = Semaphore(2)

    /** Vuelve a pedir la lista de [machine]; una petición anterior aún en vuelo se cancela. */
    fun refresh(machine: Machine, limit: Int = state.value.inboxes[machine.id]?.limit ?: PAGE) {
        listings.remove(machine.id)?.cancel()
        inbox(machine.id) { it.copy(loading = true, failure = null, limit = limit) }
        listings[machine.id] = work.launch(Dispatchers.IO) {
            try {
                val listing = client.list(machine, limit, 0)
                inbox(machine.id) { it.copy(loading = false, listing = listing, failure = null) }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                inbox(machine.id) { it.copy(loading = false, failure = e) }
            }
        }
    }

    /** Una página más de la lista. */
    fun showMore(machine: Machine) = refresh(machine, (state.value.inboxes[machine.id]?.limit ?: PAGE) + PAGE)

    /**
     * Trae [entry] al móvil para verlo, si no está ya. Lo que ya se bajó entero se usa sin volver
     * a pedirlo; una descarga en marcha no se duplica.
     */
    fun preview(machine: Machine, entry: InboxEntry) {
        val key = key(machine, entry)
        previews.cached(machine.id, entry)?.let { file -> preview(key) { Preview(entry.size, file) }; return }
        val current = state.value.previews[key]
        if (current != null && current.file == null && current.failure == null) return
        preview(key) { Preview() }
        work.launch(Dispatchers.IO) {
            downloads.withPermit {
                val destination = previews.fileFor(machine.id, entry)
                try {
                    var shown = 0L
                    client.download(machine, entry, destination) { received ->
                        if (received - shown >= PROGRESS_STEP || received >= entry.size) {
                            shown = received
                            preview(key) { it?.copy(received = received) ?: Preview(received) }
                        }
                    }
                    previews.trim(keep = destination)
                    preview(key) { Preview(entry.size, destination) }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    preview(key) { Preview(failure = e) }
                }
            }
        }
    }

    /** El estado de la copia local de [entry], si se ha pedido. */
    fun previewOf(state: State, machine: Machine, entry: InboxEntry): Preview? = state.previews[key(machine, entry)]

    /**
     * Pide al equipo cuánto borraría [deletion] sin borrar nada. Sin criterio no se pregunta:
     * se olvida la estimación anterior y el botón de borrar se queda apagado.
     */
    fun estimate(machine: Machine, deletion: InboxDeletion) {
        estimating.remove(machine.id)?.cancel()
        if (!deletion.hasCriterion) {
            mutableState.update { it.copy(estimates = it.estimates - machine.id) }
            return
        }
        val simulated = deletion.copy(dryRun = true)
        mutableState.update { it.copy(estimates = it.estimates + (machine.id to Estimate(simulated))) }
        estimating[machine.id] = work.launch(Dispatchers.IO) {
            val estimate = try {
                Estimate(simulated, result = client.delete(machine, simulated))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Estimate(simulated, failure = e)
            }
            mutableState.update { it.copy(estimates = it.estimates + (machine.id to estimate)) }
        }
    }

    /**
     * Borra de verdad lo que dice [deletion] y vuelve a pedir la lista. Las copias locales se
     * quedan hasta que la caché las tire: no molestan y así lo que estaba abierto sigue viéndose.
     */
    fun delete(machine: Machine, deletion: InboxDeletion) {
        if (!deletion.hasCriterion) return
        estimating.remove(machine.id)?.cancel()
        mutableState.update { it.copy(removals = it.removals + (machine.id to Removal()), estimates = it.estimates - machine.id) }
        work.launch(Dispatchers.IO) {
            val removal = try {
                Removal(running = false, result = client.delete(machine, deletion.copy(dryRun = false)))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Removal(running = false, failure = e)
            }
            mutableState.update { it.copy(removals = it.removals + (machine.id to removal)) }
            if (removal.result != null) refresh(machine)
        }
    }

    /** Olvida el resultado del último borrado de [machine] (el aviso ya se ha visto). */
    fun dismissRemoval(machine: Machine) = mutableState.update { it.copy(removals = it.removals - machine.id) }

    private fun inbox(machineID: String, change: (MachineInbox) -> MachineInbox) =
        mutableState.update { it.copy(inboxes = it.inboxes + (machineID to change(it.inboxes[machineID] ?: MachineInbox()))) }

    private fun preview(key: String, change: (Preview?) -> Preview) =
        mutableState.update { it.copy(previews = it.previews + (key to change(it.previews[key]))) }

    private fun key(machine: Machine, entry: InboxEntry) = "${machine.id}\u0000${entry.path}\u0000${entry.size}\u0000${entry.modified}"

    companion object {
        /** Entradas por página: la galería enseña las últimas y «Ver más» pide otra tanda. */
        const val PAGE = 60
        private const val PROGRESS_STEP = 256L * 1024
    }
}
