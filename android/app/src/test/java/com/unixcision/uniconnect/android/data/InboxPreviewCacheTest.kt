package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.InboxEntry
import com.unixcision.uniconnect.android.domain.InboxKind
import com.unixcision.uniconnect.android.domain.InboxPreviewRule
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

/** La caché de vistas previas: nombres que caducan solos, copias a medias que no cuentan y un tope. */
class InboxPreviewCacheTest {
    private val root = Files.createTempDirectory("uc-previews").toFile()

    @After
    fun limpiar() { root.deleteRecursively() }

    private fun entry(path: String, size: Long, modified: Long = 100, kind: InboxKind = InboxKind.IMAGE) =
        InboxEntry(path, "/x/$path", path.substringAfterLast('/'), size, modified, kind)

    @Test
    fun elMismoArchivoDelEquipoDaLaMismaCopiaYConSuExtension() {
        val cache = InboxPreviewCache(root)
        val a = cache.fileFor("mac", entry("20260923/Foto.JPG", 10))
        assertEquals(a, cache.fileFor("mac", entry("20260923/Foto.JPG", 10)))
        assertTrue(a.name.endsWith(".jpg"))
    }

    @Test
    fun siCambiaElArchivoOElEquipoLaCopiaViejaNoVale() {
        val cache = InboxPreviewCache(root)
        val base = cache.fileFor("mac", entry("a.mp4", 10))
        assertNotEquals(base, cache.fileFor("mac", entry("a.mp4", 11)))
        assertNotEquals(base, cache.fileFor("mac", entry("a.mp4", 10, modified = 101)))
        assertNotEquals(base, cache.fileFor("linux", entry("a.mp4", 10)))
    }

    @Test
    fun unaCopiaAMediasNoCuentaComoHecha() {
        val cache = InboxPreviewCache(root)
        val e = entry("a.jpg", 10)
        cache.fileFor("mac", e).writeBytes(ByteArray(4))
        assertNull(cache.cached("mac", e))
        cache.fileFor("mac", e).writeBytes(ByteArray(10))
        assertEquals(cache.fileFor("mac", e), cache.cached("mac", e))
    }

    @Test
    fun pasadoElTopeSeTiraLoMasViejoMenosLoQueSeEstaMirando() {
        val cache = InboxPreviewCache(root, maxBytes = 25)
        val files = (1..4).map { i -> cache.fileFor("mac", entry("$i.jpg", 10)).apply { writeBytes(ByteArray(10)); setLastModified(1_000L * i) } }
        cache.trim(keep = files[0])
        assertTrue("lo que se está mirando no se toca aunque sea lo más viejo", files[0].exists())
        assertFalse(files[1].exists())
        assertFalse(files[2].exists())
        assertTrue(files[3].exists())
    }

    @Test
    fun soloLasImagenesRazonablesSeBajanParaLaMiniatura() {
        assertTrue(InboxPreviewRule.thumbnailOnSight(entry("a.jpg", 3_000_000)))
        assertFalse(InboxPreviewRule.thumbnailOnSight(entry("a.jpg", 0)))
        assertFalse(InboxPreviewRule.thumbnailOnSight(entry("a.jpg", InboxPreviewRule.AUTO_THUMBNAIL_BYTES + 1)))
        assertFalse(InboxPreviewRule.thumbnailOnSight(entry("a.mp4", 3_000_000, kind = InboxKind.VIDEO)))
    }
}
