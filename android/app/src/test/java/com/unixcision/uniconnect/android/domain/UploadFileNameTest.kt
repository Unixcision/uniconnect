package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** A name is sent as a safe leaf with its extension, whatever the picker or a path gave. */
class UploadFileNameTest {
    @Test
    fun spacesAndOddCharactersBecomeUnderscores() {
        assertEquals("foto_de_perfil.PNG", UploadFileName.sanitize("foto de perfil.PNG"))
        assertEquals("a_b_c.txt", UploadFileName.sanitize("a<b>:c?.txt"))
        assertEquals("informe_final.pdf", UploadFileName.sanitize("informe   final.pdf"))
    }

    @Test
    fun directoriesAreDropped() {
        assertEquals("passwd", UploadFileName.sanitize("../../etc/passwd"))
        assertEquals("notas.txt", UploadFileName.sanitize("C:\\Users\\dani\\notas.txt"))
        assertEquals("a.txt", UploadFileName.sanitize("/a.txt"))
    }

    @Test
    fun accentsAreFoldedAndTheExtensionSurvives() {
        assertEquals("ano_nuevo.jpg", UploadFileName.sanitize("año nuevo.jpg"))
        assertEquals("cafe.tar.gz", UploadFileName.sanitize("café.tar.gz"))
    }

    @Test
    fun hiddenAndEmptyNamesGetAFallback() {
        assertEquals("archivo", UploadFileName.sanitize(""))
        assertEquals("archivo", UploadFileName.sanitize("   "))
        assertEquals("archivo", UploadFileName.sanitize("///"))
        assertEquals("bashrc", UploadFileName.sanitize(".bashrc"))
    }

    @Test
    fun aVeryLongNameIsCutButKeepsItsExtension() {
        val long = "x".repeat(300) + ".jpeg"
        val cut = UploadFileName.sanitize(long)
        assertTrue(cut.length <= 100)
        assertTrue(cut.endsWith(".jpeg"))
    }
}
