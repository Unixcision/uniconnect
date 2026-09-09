package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The link is found in each shape the measured services answer with, and in none of the others. */
class UploadLinkTest {
    @Test
    fun senditAnswersAWgetLine() {
        assertEquals("https://sendit.sh/lY_-J/jst3m.txt", UploadLink.extract("wget https://sendit.sh/lY_-J/jst3m.txt\n"))
    }

    @Test
    fun tempShAndLitterboxAnswerTheBareUrl() {
        assertEquals("https://temp.sh/AbCdE/notas.txt", UploadLink.extract("https://temp.sh/AbCdE/notas.txt"))
        assertEquals("https://litter.catbox.moe/x1y2z3.png", UploadLink.extract("https://litter.catbox.moe/x1y2z3.png\n"))
    }

    @Test
    fun aJsonAnswerIsReadThroughItsKnownKeys() {
        assertEquals("https://files.example/abc", UploadLink.extract("""{"ok":true,"url":"https://files.example/abc"}"""))
        assertEquals("https://files.example/def", UploadLink.extract("""{"link": "https://files.example/def", "expires": 3600}"""))
        assertEquals("https://files.example/ghi", UploadLink.extract("""{"data":{"downloadUrl":"https:\/\/files.example\/ghi"}}"""))
    }

    @Test
    fun aJsonAnswerWithoutKnownKeysStillGivesItsFirstUrl() {
        assertEquals("https://files.example/jkl", UploadLink.extract("""{"result":{"href":"https://files.example/jkl"}}"""))
    }

    @Test
    fun theFirstUrlWinsAndTrailingPunctuationIsDropped() {
        assertEquals("https://a.example/1", UploadLink.extract("Listo: https://a.example/1. Tambien https://b.example/2"))
        assertEquals("http://plain.example/x", UploadLink.extract("<p>http://plain.example/x</p>"))
    }

    @Test
    fun noUrlMeansNoLink() {
        assertNull(UploadLink.extract("ok"))
        assertNull(UploadLink.extract(""))
        assertNull(UploadLink.extract("""{"error":"quota exceeded"}"""))
        assertNull(UploadLink.extract("ftp://old.example/file"))
    }
}
