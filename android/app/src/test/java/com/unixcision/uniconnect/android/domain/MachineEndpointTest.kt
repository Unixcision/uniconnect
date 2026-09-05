package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class MachineEndpointTest {
    @Test fun acceptsTailnetBoundariesAndMagicDNSWithoutResolving() {
        listOf("100.64.0.0", "100.127.255.255", "fd7a:115c:a1e0::1234", "mac", "mac.example.ts.net")
            .forEach { assertNotNull(it, MachineEndpoint.parse(it, "58465")) }
        assertEquals("mac.example.ts.net", MachineEndpoint.parse(" MAC.EXAMPLE.TS.NET ", "58465")?.host)
        assertEquals("[fd7a:115c:a1e0::1]:58465", MachineEndpoint.parse("[fd7a:115c:a1e0::1]", "58465")?.displayAddress)
    }

    @Test fun rejectsPublicLANAndMalformedEndpoints() {
        listOf("100.63.255.255", "100.128.0.0", "192.168.1.2", "127.0.0.1", "8.8.8.8", "100.64.1.256", "100.064.1.2",
            "2001:db8::1", "fd7a:115c:a1e0:::1", "fd7a:115c:a1e0:1:2:3:4:5:6", "fd7a:115c:a1e0:1:2:3:4:5:", "host.example.org",
            "https://host.ts.net", "host.ts.net/path", "user@host", "host;whoami", "-host", "host.", "")
            .forEach { assertNull(it, MachineEndpoint.parse(it, "58465")) }
    }

    @Test fun requiresValidExplicitPort() {
        listOf("", "0", "65536", "-1", "58465/", "puerto").forEach { assertNull(MachineEndpoint.parse("mac", it)) }
        assertNotNull(MachineEndpoint.parse("mac", "1"))
        assertNotNull(MachineEndpoint.parse("mac", "65535"))
    }
}
