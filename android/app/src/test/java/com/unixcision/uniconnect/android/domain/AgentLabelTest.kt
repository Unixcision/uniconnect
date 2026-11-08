package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Hosts send tokens; people read names. */
class AgentLabelTest {
    @Test
    fun knownTokensReadAsTheirProductNames() {
        assertEquals("Claude", AgentLabel.of("claude"))
        assertEquals("Codex", AgentLabel.of(" CODEX "))
        assertEquals("Antigravity", AgentLabel.of("agy"))
        assertEquals("Antigravity", AgentLabel.of("antigravity"))
    }

    @Test
    fun anUnknownTokenIsCapitalisedAndNoTokenIsNoAI() {
        assertEquals("Grok", AgentLabel.of("grok"))
        assertNull(AgentLabel.of(null))
        assertNull(AgentLabel.of("  "))
        // A JSON null read with optString arrives as the text "null": no AI, not an AI called Null.
        assertNull(AgentLabel.of("null"))
        assertNull(AgentLabel.of("NULL"))
    }
}
