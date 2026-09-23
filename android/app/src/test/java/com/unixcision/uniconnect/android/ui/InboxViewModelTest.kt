package com.unixcision.uniconnect.android.ui

import com.unixcision.uniconnect.android.data.InboxPreviewCache
import com.unixcision.uniconnect.android.domain.InboxClient
import com.unixcision.uniconnect.android.domain.InboxDeletion
import com.unixcision.uniconnect.android.domain.InboxDeletionResult
import com.unixcision.uniconnect.android.domain.InboxEntry
import com.unixcision.uniconnect.android.domain.InboxKind
import com.unixcision.uniconnect.android.domain.InboxListing
import com.unixcision.uniconnect.android.domain.Machine
import com.unixcision.uniconnect.android.domain.MachineEndpoint
import com.unixcision.uniconnect.android.domain.MachineFailure
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.Collections

/** La bandeja vista desde el móvil: listar, simular antes de borrar, borrar y no bajar dos veces lo mismo. */
class InboxViewModelTest {
    private val machine = Machine("mac", "Mac", requireNotNull(MachineEndpoint.parse("100.64.0.1", "58465")))
    private val foto = InboxEntry("20260923/foto.jpg", "/Users/d/UniConnect/Entrada/20260923/foto.jpg", "foto.jpg", 5, 100, InboxKind.IMAGE)
    private val folder = Files.createTempDirectory("uc-inbox-vm").toFile()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @After
    fun limpiar() { scope.cancel(); folder.deleteRecursively() }

    private class FakeClient(var listing: InboxListing = InboxListing(0, 0, null, null, emptyList())) : InboxClient {
        val lists = Collections.synchronizedList(mutableListOf<Int>())
        val deletions = Collections.synchronizedList(mutableListOf<InboxDeletion>())
        val downloads = Collections.synchronizedList(mutableListOf<String>())
        var failList = false
        override suspend fun list(machine: Machine, limit: Int, offset: Int): InboxListing {
            lists += limit
            if (failList) throw MachineFailure.Transport()
            return listing
        }
        override suspend fun delete(machine: Machine, deletion: InboxDeletion): InboxDeletionResult {
            deletions += deletion
            return InboxDeletionResult(deletion.dryRun, 1, 5, 0, 0)
        }
        override suspend fun download(machine: Machine, entry: InboxEntry, destination: File, progress: (Long) -> Unit) {
            downloads += entry.path
            destination.parentFile?.mkdirs()
            destination.writeBytes(ByteArray(entry.size.toInt()))
            progress(entry.size)
        }
    }

    private fun model(client: FakeClient) = InboxViewModel(client, InboxPreviewCache(folder), scope)

    @Test
    fun laListaQuedaPorEquipoYUnFalloTambien() = runBlocking {
        val client = FakeClient(InboxListing(1, 5, 100, 100, listOf(foto)))
        val model = model(client)
        model.refresh(machine)
        val listo = withTimeout(3_000) { model.state.first { it.inboxes["mac"]?.listing != null } }
        assertEquals(listOf(foto), listo.inboxes.getValue("mac").listing!!.entries)
        client.failList = true
        model.refresh(machine)
        val fallo = withTimeout(3_000) { model.state.first { it.inboxes["mac"]?.failure != null } }
        assertEquals("la lista anterior se sigue enseñando", 1, fallo.inboxes.getValue("mac").listing!!.count)
    }

    @Test
    fun verMasPideOtraPagina() = runBlocking {
        val client = FakeClient()
        val model = model(client)
        model.refresh(machine)
        withTimeout(3_000) { model.state.first { it.inboxes["mac"]?.loading == false } }
        model.showMore(machine)
        withTimeout(3_000) { model.state.first { it.inboxes["mac"]?.let { i -> !i.loading && i.limit == 2 * InboxViewModel.PAGE } == true } }
        assertEquals(listOf(InboxViewModel.PAGE, 2 * InboxViewModel.PAGE), client.lists.toList())
    }

    @Test
    fun sinCriterioNoSePreguntaYConCriterioSoloSeSimula() = runBlocking {
        val client = FakeClient()
        val model = model(client)
        model.estimate(machine, InboxDeletion())
        assertTrue(client.deletions.isEmpty())
        model.estimate(machine, InboxDeletion(olderThanDays = 30))
        val estimado = withTimeout(3_000) { model.state.first { it.estimates["mac"]?.result != null } }
        assertTrue(estimado.estimates.getValue("mac").result!!.dryRun)
        assertEquals(listOf(true), client.deletions.map { it.dryRun })
    }

    @Test
    fun borrarDeVerdadYDespuesVuelveAListar() = runBlocking {
        val client = FakeClient()
        val model = model(client)
        model.estimate(machine, InboxDeletion(everything = true))
        withTimeout(3_000) { model.state.first { it.estimates["mac"]?.result != null } }
        model.delete(machine, InboxDeletion(everything = true, dryRun = true))
        withTimeout(3_000) { model.state.first { it.removals["mac"]?.running == false && it.inboxes["mac"]?.loading == false } }
        assertEquals("aunque llegue marcado como simulación, borrar es borrar", false, client.deletions.last().dryRun)
        assertEquals(1, client.lists.size)
        assertTrue("la estimación vieja ya no vale", model.state.value.estimates["mac"] == null)
    }

    @Test
    fun loQueYaEstaBajadoNoSeVuelveAPedir() = runBlocking {
        val client = FakeClient()
        val model = model(client)
        model.preview(machine, foto)
        val listo = withTimeout(3_000) { model.state.first { s -> model.previewOf(s, machine, foto)?.file != null } }
        assertEquals(5L, model.previewOf(listo, machine, foto)!!.file!!.length())
        model.preview(machine, foto)
        assertEquals(listOf(foto.path), client.downloads.toList())
    }
}
