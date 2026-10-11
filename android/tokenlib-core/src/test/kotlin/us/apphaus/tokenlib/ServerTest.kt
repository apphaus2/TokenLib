package us.apphaus.tokenlib

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class ServerTest {
    private lateinit var transport: FakeTransport
    private lateinit var server: TokenServer

    @Before fun setUp() {
        transport = FakeTransport()
        transport.responses["api.anthropic.com"] = 200 to Canned.anthropic
        transport.responses["api.openai.com"] = 200 to Canned.openai
        server = TokenServer(InMemoryStore(), PlainCipher, transport)
    }

    private fun stream(session: TokenSession, text: String = "sing"): Pair<Result<ChatReply>?, List<String>> {
        var result: Result<ChatReply>? = null
        val deltas = ArrayList<String>()
        session.stream(ChatRequest("bush", listOf(ChatMessage.user(text))), { deltas += it }) { result = it }
        return result to deltas
    }

    @Test fun notReadyWithoutProviderOrKey() {
        assertFalse(server.isReady)
        val client = TokenClient(server)
        var (result, _) = stream(client.session("bush", Profile.CHARACTER))
        assertTrue(result!!.exceptionOrNull() is TokenLibException.NoProvider)
        server.update { it.copy(activeProvider = ProviderKind.ANTHROPIC) }
        assertFalse(server.isReady)
        result = stream(client.session("bush", Profile.CHARACTER)).first
        assertEquals(TokenLibException.MissingKey(ProviderKind.ANTHROPIC), result!!.exceptionOrNull())
        server.activate(ProviderKind.LOCAL)
        assertFalse(server.isReady)
        server.update { it.copy(localBaseUrl = "http://h/v1") }
        assertTrue(server.isReady)
    }

    @Test fun streamsRecordsUsageAndEncryptsKeys() {
        val xor = object : SecretCipher {
            override fun encrypt(plaintext: ByteArray) = ByteArray(plaintext.size) { (plaintext[it].toInt() xor 0x2A).toByte() }
            override fun decrypt(ciphertext: ByteArray) = encrypt(ciphertext)
        }
        val store = InMemoryStore()
        server = TokenServer(store, xor, transport)
        server.activate(ProviderKind.ANTHROPIC, " sk-live ")
        assertEquals("sk-live", String(xor.decrypt(store.keyData(ProviderKind.ANTHROPIC)!!)))
        assertFalse(String(store.keyData(ProviderKind.ANTHROPIC)!!) == "sk-live")
        assertEquals("sk-live", server.key(ProviderKind.ANTHROPIC))
        assertTrue(server.isReady)
        assertEquals("claude-opus-5-5", server.model(Profile.CHARACTER)?.id)
        val session = TokenClient(server).session("bush", Profile.CHARACTER, budget = 1000)
        val (result, deltas) = stream(session)
        val reply = result!!.getOrThrow()
        assertEquals("Ask, and the bush shall sing.", reply.text)
        assertEquals(listOf("Ask, ", "and the bush shall sing."), deltas)
        assertEquals(Usage(25, 9), reply.usage)
        assertEquals("claude-opus-5-5", reply.model)
        assertEquals(ProviderKind.ANTHROPIC, reply.provider)
        assertEquals(34, session.spent)
        assertEquals(966, session.remaining)
        assertEquals("sk-live", transport.requests.last().headers["x-api-key"])
        val usage = server.usageToday()
        assertEquals(1, usage.requests)
        assertEquals(34, usage.totalTokens)
        assertEquals(25L * 4 + 9L * 20, usage.costMicros)
        val row = server.recentUsage().first()
        assertEquals("bush", row.consumer)
        assertEquals("claude-opus-5-5", row.model)
        assertNull(row.prompt)
    }

    @Test fun sessionBudgetAndDailyCap() {
        server.activate(ProviderKind.ANTHROPIC, "k")
        val client = TokenClient(server)
        val small = client.session("bush", Profile.CHARACTER, budget = 36)
        var (result, _) = stream(small)
        assertTrue(result!!.isSuccess)
        assertEquals(2, small.remaining)
        assertFalse(small.isExhausted)
        result = stream(small).first
        assertTrue(result!!.exceptionOrNull() is TokenLibException.BudgetExhausted)
        assertNull(server.remainingToday())
        server.update { it.copy(dailyTokenCap = 100) }
        assertEquals(66, server.remainingToday())
        server.update { it.copy(dailyTokenCap = 20) }
        assertEquals(0, server.remainingToday())
        server.update { it.copy(dailyTokenCap = 36) }
        result = stream(client.session("snoopy", Profile.FAST)).first
        assertTrue(result!!.exceptionOrNull() is TokenLibException.DailyCapReached)
    }

    @Test fun creditCountsDownAndSurvivesClearingUsage() {
        server.activate(ProviderKind.ANTHROPIC, "k")
        assertNull(server.credit())
        server.setCredit(50_000_000, ProviderKind.ANTHROPIC)
        val session = TokenClient(server).session("bush", Profile.CHARACTER)
        stream(session)
        assertEquals(Credit(50_000_000, 280), server.credit())
        assertEquals(49_999_720L, server.credit()?.remainingMicros)
        server.store.deleteAll()
        stream(session)
        assertEquals(560L, server.credit()?.spentMicros)
        assertNull(server.credit(ProviderKind.OPENAI))
        server.setCredit(100, ProviderKind.ANTHROPIC)
        stream(session)
        assertEquals(0L, server.credit()?.remainingMicros)
        server.setCredit(null, ProviderKind.ANTHROPIC)
        assertNull(server.credit())
    }

    @Test fun switchingProviderAndLoggingPrompts() {
        server.activate(ProviderKind.ANTHROPIC, "a")
        server.activate(ProviderKind.OPENAI, "o")
        server.update { it.copy(logPrompts = true) }
        assertEquals(listOf(ProviderKind.ANTHROPIC, ProviderKind.OPENAI), server.configuredProviders)
        assertEquals("gpt-5-nano", server.model(Profile.FAST)?.id)
        val (result, _) = stream(TokenClient(server).session("x", Profile.FAST), "hello?")
        assertEquals("Hello there", result!!.getOrThrow().text)
        val row = server.recentUsage().first()
        assertEquals(ProviderKind.OPENAI, row.provider)
        assertEquals("hello?", row.prompt)
        assertEquals("Hello there", row.reply)
    }

    @Test fun openAICompatibleVendorsServeProfiles() {
        transport.responses["api.deepseek.com"] = 200 to Canned.openai
        transport.responses["api.moonshot.ai"] = 200 to Canned.openai
        transport.responses["dashscope-intl.aliyuncs.com"] = 200 to Canned.openai
        transport.responses["api.x.ai"] = 200 to Canned.openai
        transport.responses["api.mistral.ai"] = 200 to Canned.openai
        transport.responses["api.cohere.com"] = 200 to Canned.openai
        transport.responses["openrouter.ai"] = 200 to Canned.openai
        for ((kind, model) in listOf(ProviderKind.DEEPSEEK to "deepseek-v4-pro", ProviderKind.KIMI to "kimi-k3", ProviderKind.QWEN to "qwen3.8-max", ProviderKind.GROK to "grok-4.7",
                ProviderKind.MISTRAL to "mistral-large-latest", ProviderKind.COHERE to "command-a-plus-05-2026", ProviderKind.OPENROUTER to "anthropic/claude-opus-5.5")) {
            server.activate(kind, "k-${kind.id}")
            assertTrue(server.isReady)
            assertEquals(model, server.model(Profile.CHARACTER)?.id)
            val (result, _) = stream(TokenClient(server).session("bush", Profile.CHARACTER))
            val reply = result!!.getOrThrow()
            assertEquals("Hello there", reply.text)
            assertEquals(kind, reply.provider)
            assertEquals(model, reply.model)
            assertEquals("Bearer k-${kind.id}", transport.requests.last().headers["Authorization"])
            assertEquals(kind, server.recentUsage().first().provider)
        }
        assertEquals(listOf(ProviderKind.DEEPSEEK, ProviderKind.KIMI, ProviderKind.QWEN, ProviderKind.GROK, ProviderKind.MISTRAL, ProviderKind.COHERE, ProviderKind.OPENROUTER), server.configuredProviders)
        assertEquals(7, server.usageToday().requests)
    }

    /** A cipher that marks its output, so a wrong key fails the way AES-GCM's tag check does. */
    private class Tagged(val tag: Byte) : SecretCipher {
        override fun encrypt(plaintext: ByteArray) = byteArrayOf(tag) + plaintext
        override fun decrypt(ciphertext: ByteArray): ByteArray {
            require(ciphertext.firstOrNull() == tag) { "wrong key" }
            return ciphertext.copyOfRange(1, ciphertext.size)
        }
    }

    @Test fun reencryptKeysMovesKeysToANewCipher() {
        val store = InMemoryStore()
        val old = TokenServer(store, Tagged(1), transport)
        old.setKey("sk-a", ProviderKind.ANTHROPIC)
        old.setKey("sk-o", ProviderKind.OPENAI)
        val server = TokenServer(store, Tagged(2), transport)
        assertFalse(server.keysReadable)
        assertEquals(listOf(ProviderKind.ANTHROPIC, ProviderKind.OPENAI), server.reencryptKeys(Tagged(1)))
        assertTrue(server.keysReadable)
        assertEquals("sk-a", server.key(ProviderKind.ANTHROPIC))
        assertEquals("sk-o", server.key(ProviderKind.OPENAI))
        assertEquals(emptyList<ProviderKind>(), server.reencryptKeys(Tagged(1)))
        assertEquals("sk-a", server.key(ProviderKind.ANTHROPIC))
    }

    @Test fun httpErrorsSurface() {
        server.activate(ProviderKind.ANTHROPIC, "k")
        transport.responses["api.anthropic.com"] = 401 to """{"error":{"message":"invalid x-api-key"}}"""
        val (result, _) = stream(TokenClient(server).session("x", Profile.CHARACTER))
        assertEquals(TokenLibException.Http(401, """{"error":{"message":"invalid x-api-key"}}"""), result!!.exceptionOrNull())
        assertEquals(0, server.usageToday().requests)
    }

    @Test fun refusalIsAStopReasonNotAnError() {
        server.activate(ProviderKind.ANTHROPIC, "k")
        transport.responses["api.anthropic.com"] = 200 to Canned.anthropicRefusal
        val (result, _) = stream(TokenClient(server).session("x", Profile.VISION))
        assertEquals(StopReason.REFUSAL, result!!.getOrThrow().stop)
        assertEquals(1, server.usageToday().requests)
    }

    @Test fun imagePartsCountAgainstBudget() {
        server.activate(ProviderKind.ANTHROPIC, "k")
        val session = TokenClient(server).session("eye", Profile.VISION, budget = 1000)
        var result: Result<ChatReply>? = null
        session.send(ChatRequest(messages = listOf(ChatMessage.user(listOf(ChatPart.Text("look"), ChatPart.Image("AAAA", "image/png")))))) { result = it }
        assertTrue(result!!.exceptionOrNull() is TokenLibException.BudgetExhausted)
        assertTrue(transport.requests.isEmpty())
    }
}
