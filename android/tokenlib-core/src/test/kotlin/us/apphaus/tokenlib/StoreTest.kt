package us.apphaus.tokenlib

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class StoreTest {
    private fun stores(): List<Pair<String, TokenStore>> {
        val path = File.createTempFile("tokenlib-", ".sqlite").also { it.delete() }.path
        return listOf("memory" to InMemoryStore(), "sqlite" to SQLiteStore(JdbcSqlDatabase(path)))
    }

    @Test fun keysSettingsAndUsage() {
        for ((name, store) in stores()) {
            assertNull(name, store.keyData(ProviderKind.ANTHROPIC))
            store.setKeyData("secret".toByteArray(), ProviderKind.ANTHROPIC)
            store.setKeyData("other".toByteArray(), ProviderKind.OPENAI)
            assertEquals(name, "secret", String(store.keyData(ProviderKind.ANTHROPIC)!!))
            assertEquals(name, listOf(ProviderKind.ANTHROPIC, ProviderKind.OPENAI), store.providersWithKeys())
            store.setKeyData("rotated".toByteArray(), ProviderKind.ANTHROPIC)
            assertEquals(name, "rotated", String(store.keyData(ProviderKind.ANTHROPIC)!!))
            store.setKeyData(null, ProviderKind.OPENAI)
            assertEquals(name, listOf(ProviderKind.ANTHROPIC), store.providersWithKeys())

            assertEquals(name, Settings(), store.settings())
            val s = Settings(ProviderKind.LOCAL, "http://h:1/v1", "llama3", 5000, true, mapOf(ProviderKind.ANTHROPIC to Credit(50_000_000, 40_000)), enabled = false)
            store.save(s)
            assertEquals(name, s, store.settings())
            store.save(Settings(ProviderKind.ANTHROPIC))
            assertNull(name, store.settings().dailyTokenCap)
            assertEquals(name, emptyMap<ProviderKind, Credit>(), store.settings().credits)

            val now = System.currentTimeMillis()
            val old = now - 2 * 86_400_000L
            store.record(UsageRecord(at = old, consumer = "bush", profile = Profile.CHARACTER, provider = ProviderKind.ANTHROPIC, model = "m", promptTokens = 100, replyTokens = 10, costMicros = 750, stop = StopReason.END))
            val r = store.record(UsageRecord(at = now, consumer = "bush", profile = Profile.CHARACTER, provider = ProviderKind.ANTHROPIC, model = "m", promptTokens = 50, replyTokens = 5, costMicros = 375, stop = StopReason.END, prompt = "p", reply = "r"))
            store.record(UsageRecord(at = now, consumer = "snoopy", profile = Profile.FAST, provider = ProviderKind.OPENAI, model = "n", promptTokens = 1, replyTokens = 1, costMicros = 1, stop = StopReason.MAX_TOKENS))
            assertNotNull(name, r.id)
            assertEquals(name, UsageTotals(3, 151, 16, 1126), store.totals(now - 3 * 86_400_000L))
            assertEquals(name, UsageTotals(1, 50, 5, 375), store.totals(now - 3_600_000L, "bush"))
            val recent = store.recent(2)
            assertEquals(name, listOf("snoopy", "bush"), recent.map { it.consumer })
            assertEquals(name, "r", recent[1].reply)
            assertEquals(name, StopReason.MAX_TOKENS, recent[0].stop)
            store.deleteAll()
            assertEquals(name, 0, store.recent(5).size)
        }
    }

    @Test fun moveDatabaseRenamesTheFileWithItsSideFiles() {
        val directory = java.nio.file.Files.createTempDirectory("tokenlib-move-").toFile()
        val legacy = File(directory, "tokenx.sqlite")
        val current = File(directory, "tokenlib.sqlite")
        SQLiteStore(JdbcSqlDatabase(legacy.path)).apply {
            setKeyData("secret".toByteArray(), ProviderKind.ANTHROPIC)
            save(Settings(activeProvider = ProviderKind.ANTHROPIC, dailyTokenCap = 500))
        }
        assertTrue(SQLiteStore.moveDatabase(legacy, current))
        assertFalse(legacy.exists())
        val moved = SQLiteStore(JdbcSqlDatabase(current.path))
        assertEquals("secret", String(moved.keyData(ProviderKind.ANTHROPIC)!!))
        assertEquals(500, moved.settings().dailyTokenCap)
        assertFalse("nothing left to move", SQLiteStore.moveDatabase(legacy, current))
        SQLiteStore(JdbcSqlDatabase(legacy.path))
        assertFalse("an existing database is never overwritten", SQLiteStore.moveDatabase(legacy, current))
        assertTrue(legacy.exists())
    }
}
