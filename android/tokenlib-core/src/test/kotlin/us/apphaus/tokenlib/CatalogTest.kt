package us.apphaus.tokenlib

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CatalogTest {
    @Test fun everyProviderHasEveryTierOrFallsBack() {
        for (provider in ProviderKind.entries) for (profile in Profile.entries) {
            val model = Catalog.model(profile, provider)
            assertEquals(provider, model.provider)
            if (provider == ProviderKind.LOCAL || provider == ProviderKind.APPLE) assertFalse(model.vision)
        }
        assertEquals("claude-opus-5-5", Catalog.model(Profile.CHARACTER, ProviderKind.ANTHROPIC).id)
        assertEquals("claude-haiku-4-5", Catalog.model(Profile.FAST, ProviderKind.ANTHROPIC).id)
        assertEquals(ModelTier.FAST, Catalog.model(Profile.FAST, ProviderKind.OPENAI).tier)
        assertEquals("deepseek-v4-pro", Catalog.model(Profile.CHARACTER, ProviderKind.DEEPSEEK).id)
        assertEquals("deepseek-flash", Catalog.model(Profile.VISION, ProviderKind.DEEPSEEK).id)
        assertEquals("kimi-k2.6", Catalog.model(Profile.FAST, ProviderKind.KIMI).id)
        assertEquals("kimi-k3", Catalog.model(Profile.VISION, ProviderKind.KIMI).id)
        assertEquals("qwen3.8-flash", Catalog.model(Profile.FAST, ProviderKind.QWEN).id)
        assertEquals("qwen3.8-max", Catalog.model(Profile.VISION, ProviderKind.QWEN).id)
        assertEquals("grok-4.3", Catalog.model(Profile.FAST, ProviderKind.GROK).id)
        assertEquals("grok-4.7", Catalog.model(Profile.VISION, ProviderKind.GROK).id)
        assertEquals("mistral-large-latest", Catalog.model(Profile.CHARACTER, ProviderKind.MISTRAL).id)
        assertEquals("mistral-small-latest", Catalog.model(Profile.FAST, ProviderKind.MISTRAL).id)
        assertEquals("command-a-plus-05-2026", Catalog.model(Profile.VISION, ProviderKind.COHERE).id)
        assertEquals("command-r7b-12-2024", Catalog.model(Profile.FAST, ProviderKind.COHERE).id)
        assertEquals("anthropic/claude-opus-5.5", Catalog.model(Profile.CHARACTER, ProviderKind.OPENROUTER).id)
        assertEquals("anthropic/claude-haiku-4.5", Catalog.model(Profile.FAST, ProviderKind.OPENROUTER).id)
        assertTrue(listOf(ProviderKind.DEEPSEEK, ProviderKind.KIMI, ProviderKind.QWEN, ProviderKind.GROK, ProviderKind.MISTRAL, ProviderKind.COHERE, ProviderKind.OPENROUTER).all { it.needsKey })
        assertEquals(listOf("anthropic", "openai", "gemini", "deepseek", "kimi", "qwen", "grok", "mistral", "cohere", "openrouter", "apple", "local"), ProviderKind.entries.map { it.id })
        assertEquals("apple-on-device", Catalog.model(Profile.ASSISTANT, ProviderKind.APPLE).id)
        assertEquals(0L, Catalog.model("apple-on-device")!!.costMicros(1000, 1000))
        assertFalse(ProviderKind.APPLE.needsKey)
        assertTrue(ProviderKind.APPLE.isNative)
        assertEquals(listOf(ProviderKind.APPLE), ProviderKind.entries.filter { it.isNative })
        assertEquals(ProviderKind.GEMINI, Catalog.model("gemini-2.5-flash")?.provider)
        assertNull(Catalog.model("nope"))
    }

    @Test fun costAndProfiles() {
        val opus = Catalog.model("claude-opus-5-5")!!
        assertEquals(4_000_000L, opus.costMicros(1_000_000, 0))
        assertEquals(6000L, opus.costMicros(1000, 100))
        assertEquals(ModelTier.BALANCED, Catalog.model("claude-sonnet-5-5")?.tier)
        assertEquals("low", Profile.CHARACTER.effort)
        assertEquals(4096, Profile.ASSISTANT.maxTokens)
        assertTrue(Profile.VISION.needsVision)
        assertFalse(ProviderKind.LOCAL.needsKey)
    }

    @Test fun chatRequestEstimate() {
        val r = ChatRequest(system = "a".repeat(40), messages = listOf(ChatMessage.user("b".repeat(32))))
        assertEquals(20, r.estimatedPromptTokens)
        val withImage = ChatRequest(messages = listOf(ChatMessage.user(listOf(ChatPart.Text("look"), ChatPart.Image("AAAA", "image/png")))))
        assertEquals("look", withImage.messages[0].text)
        assertEquals(1, withImage.messages[0].imageCount)
        assertTrue(withImage.estimatedPromptTokens >= 1600)
    }

    @Test fun miniJsonRoundTrip() {
        val text = """{"a":[1,2.5,"x\n\"y\""],"b":{"c":true,"d":null},"e":-3}"""
        val parsed = MiniJson.parse(text) as Map<*, *>
        assertEquals(listOf(1.0, 2.5, "x\n\"y\""), parsed["a"])
        assertEquals(true, parsed.obj("b")?.get("c"))
        assertEquals(-3, parsed.int("e"))
        assertEquals("""{"a":[1,2.5,"x\n\"y\""],"b":{"c":true,"d":null},"e":-3}""", MiniJson.stringify(parsed))
        assertNull(MiniJson.parse("{bad"))
    }
}
