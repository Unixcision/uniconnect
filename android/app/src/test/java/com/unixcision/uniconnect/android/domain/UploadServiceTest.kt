package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Where each style sends a file, and how a typed domain is cleaned. */
class UploadServiceTest {
    @Test
    fun eachStyleHasItsOwnPath() {
        assertEquals("https://sendit.sh/notas.txt", UploadService("sendit.sh", UploadStyle.RAW_NAMED).uploadUrl("notas.txt"))
        assertEquals("https://temp.sh/upload", UploadService("temp.sh", UploadStyle.MULTIPART_FILE).uploadUrl("notas.txt"))
        assertEquals("https://litterbox.catbox.moe/resources/internals/api.php", UploadService("litterbox.catbox.moe", UploadStyle.LITTERBOX).uploadUrl("notas.txt"))
        assertEquals("https://transfer.sh/notas.txt", UploadService("transfer.sh", UploadStyle.RAW_NAMED).uploadUrl("notas.txt"))
    }

    @Test
    fun aRawNameIsEncodedInThePath() {
        assertEquals("https://sendit.sh/a%20b%26c.txt", UploadService("sendit.sh", UploadStyle.RAW_NAMED).uploadUrl("a b&c.txt"))
    }

    @Test
    fun aDomainWithItsOwnSchemeIsUsedAsTyped() {
        assertEquals("http://127.0.0.1:8080/x.bin", UploadService("http://127.0.0.1:8080", UploadStyle.RAW_NAMED).uploadUrl("x.bin"))
        assertEquals("https://files.example/upload", UploadService("https://files.example/", UploadStyle.MULTIPART_FILE).uploadUrl("x.bin"))
    }

    @Test
    fun senditIsTheDefaultAndPresetsAreKnown() {
        assertEquals(UploadService("sendit.sh", UploadStyle.RAW_NAMED), UploadService.default)
        assertEquals(listOf("sendit.sh", "temp.sh", "litterbox.catbox.moe", "transfer.sh"), UploadService.presets.map { it.domain })
        assertTrue(UploadService.default.isPreset)
        assertFalse(UploadService("mi.servidor.es", UploadStyle.RAW_NAMED).isPreset)
        assertFalse(UploadService("sendit.sh", UploadStyle.MULTIPART_FILE).isPreset)
    }

    @Test
    fun aTypedDomainIsCleaned() {
        assertEquals("files.example", UploadService.normalizeDomain("  https://Files.Example/upload "))
        assertEquals("files.example", UploadService.normalizeDomain("files.example/"))
        assertEquals("http://192.168.1.4:8080", UploadService.normalizeDomain("http://192.168.1.4:8080/x"))
        assertEquals("", UploadService.normalizeDomain("https://"))
        assertEquals("", UploadService.normalizeDomain("   "))
    }

    @Test
    fun anUnknownStoredStyleFallsBackToRaw() {
        assertEquals(UploadStyle.RAW_NAMED, UploadStyle.named("PIGEON"))
        assertEquals(UploadStyle.LITTERBOX, UploadStyle.named("LITTERBOX"))
    }
}
