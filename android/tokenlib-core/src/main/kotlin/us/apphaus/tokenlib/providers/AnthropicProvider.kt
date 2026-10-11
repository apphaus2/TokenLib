/*
 * AnthropicProvider.kt
 * TokenLib
 *
 * Anthropic Messages API over HTTPS with server-sent events.
 */
package us.apphaus.tokenlib.providers

import us.apphaus.tokenlib.ChatEvent
import us.apphaus.tokenlib.ChatMessage
import us.apphaus.tokenlib.ChatPart
import us.apphaus.tokenlib.ChatRequest
import us.apphaus.tokenlib.HttpRequest
import us.apphaus.tokenlib.MiniJson
import us.apphaus.tokenlib.Provider
import us.apphaus.tokenlib.ProviderCall
import us.apphaus.tokenlib.ProviderKind
import us.apphaus.tokenlib.ProviderStreamParser
import us.apphaus.tokenlib.SseParser
import us.apphaus.tokenlib.SseStreamParser
import us.apphaus.tokenlib.StopReason
import us.apphaus.tokenlib.TokenLibException
import us.apphaus.tokenlib.int
import us.apphaus.tokenlib.obj
import us.apphaus.tokenlib.str

class AnthropicProvider : Provider {
    override val kind = ProviderKind.ANTHROPIC

    override fun request(chat: ChatRequest, call: ProviderCall): HttpRequest {
        val key = call.key?.takeIf { it.isNotEmpty() } ?: throw TokenLibException.MissingKey(ProviderKind.ANTHROPIC)
        val fiveGeneration = isFiveGeneration(call.model.id)
        val body = linkedMapOf<String, Any?>(
            "model" to call.model.id,
            "max_tokens" to (chat.maxTokens ?: call.maxTokens),
            "stream" to true,
            "messages" to messages(chat.messages),
        )
        chat.system?.takeIf { it.isNotEmpty() }?.let { body["system"] = it }
        // Sampling parameters are rejected on the 5-generation models; thinking effort takes their place there.
        val temperature = chat.temperature ?: call.profile.temperature
        if (temperature != null && !fiveGeneration) body["temperature"] = temperature
        val outputConfig = linkedMapOf<String, Any?>()
        if (fiveGeneration) call.profile.effort?.let { outputConfig["effort"] = it }
        chat.jsonSchema?.let { outputConfig["format"] = mapOf("type" to "json_schema", "schema" to it) }
        if (outputConfig.isNotEmpty()) body["output_config"] = outputConfig
        val headers = linkedMapOf("Content-Type" to "application/json", "x-api-key" to key, "anthropic-version" to VERSION, "Accept" to "text/event-stream")
        if (supportsFallbacks(call.model.id)) {
            headers["anthropic-beta"] = FALLBACK_BETA
            body["fallbacks"] = "default"
        }
        return HttpRequest(ENDPOINT, headers = headers, body = MiniJson.stringify(body).toByteArray())
    }

    override fun makeParser(): ProviderStreamParser = Parser()

    private class Parser : SseStreamParser() {
        override fun handle(event: SseParser.Event): List<ChatEvent> {
            val json = MiniJson.parse(event.data) ?: return emptyList()
            when (json.str("type")) {
                "message_start" -> json.obj("message").obj("usage")?.int("input_tokens")?.let { usage = usage.copy(promptTokens = it) }
                "content_block_delta" -> {
                    val delta = json.obj("delta")
                    if (delta.str("type") == "text_delta") delta.str("text")?.takeIf { it.isNotEmpty() }?.let { return listOf(ChatEvent.Text(it)) }
                }
                "message_delta" -> {
                    json.obj("usage")?.int("output_tokens")?.let { usage = usage.copy(replyTokens = it) }
                    json.obj("delta").str("stop_reason")?.let { stop = stopReason(it) }
                }
                "message_stop" -> { finished = true; return listOf(ChatEvent.Done(usage, stop)) }
                "error" -> { finished = true; return listOf(ChatEvent.Done(usage, StopReason.OTHER), ChatEvent.Text(json.obj("error").str("message") ?: "error")) }
            }
            return emptyList()
        }
    }

    companion object {
        const val ENDPOINT = "https://api.anthropic.com/v1/messages"
        const val VERSION = "2023-06-01"
        /** Server-side refusal fallbacks (`fallbacks: "default"`) for the models that run safety classifiers. */
        const val FALLBACK_BETA = "server-side-fallback-2026-07-01"

        /** The 5-generation models take `output_config.effort` and reject sampling parameters. */
        fun isFiveGeneration(id: String) = id.startsWith("claude-opus-5") || id.startsWith("claude-sonnet-5") || id.startsWith("claude-fable-5")
        /** The models that accept `fallbacks: "default"` under the fallback beta header. */
        fun supportsFallbacks(id: String) = id.startsWith("claude-opus-5") || id.startsWith("claude-sonnet-5-5") || id.startsWith("claude-fable-5")

        /** Content blocks for a message: text blocks and base64 image blocks. */
        fun blocks(message: ChatMessage): List<Map<String, Any?>> = message.contentParts.map { part ->
            when (part) {
                is ChatPart.Text -> mapOf("type" to "text", "text" to part.text)
                is ChatPart.Image -> mapOf("type" to "image", "source" to mapOf("type" to "base64", "media_type" to part.mediaType, "data" to part.data))
            }
        }

        /**
         * Anthropic requires alternating roles starting with `user`; adjacent same-role turns are merged.
         * Text-only messages are sent as a string, messages with parts as content blocks.
         */
        @Suppress("UNCHECKED_CAST")
        fun messages(messages: List<ChatMessage>): List<Map<String, Any?>> {
            val out = ArrayList<LinkedHashMap<String, Any?>>()
            for (m in messages) {
                val role = m.role.id
                val last = out.lastOrNull()
                if (last != null && last["role"] == role) {
                    val content = last["content"]
                    if (content is String && m.parts == null) last["content"] = content + "\n" + m.text
                    else {
                        val previous = if (content is String) listOf(mapOf("type" to "text", "text" to content)) else content as List<Map<String, Any?>>
                        last["content"] = previous + blocks(m)
                    }
                } else out += linkedMapOf("role" to role, "content" to (if (m.parts == null) m.text else blocks(m)))
            }
            if (out.firstOrNull()?.get("role") != "user") out.add(0, linkedMapOf("role" to "user", "content" to "(start)"))
            return out
        }

        fun stopReason(reason: String): StopReason = when (reason) {
            "end_turn", "stop_sequence" -> StopReason.END
            "max_tokens" -> StopReason.MAX_TOKENS
            "refusal" -> StopReason.REFUSAL
            else -> StopReason.OTHER
        }
    }
}
