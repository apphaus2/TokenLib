package us.apphaus.tokenlib

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TransportTest {
    @Test fun sseParser() {
        val p = SseParser()
        assertNull(p.feed("event: ping"))
        assertNull(p.feed(": comment"))
        assertNull(p.feed("data: {\"a\":1}"))
        assertNull(p.feed("data: more"))
        assertEquals(SseParser.Event("ping", "{\"a\":1}\nmore"), p.feed(""))
        assertNull(p.feed(""))
        assertNull(p.feed("data:no-space"))
        assertEquals("no-space", p.feed("")?.data)
    }
}
