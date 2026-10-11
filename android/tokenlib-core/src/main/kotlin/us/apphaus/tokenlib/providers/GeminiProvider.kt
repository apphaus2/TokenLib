/*
 * GeminiProvider.kt
 * TokenLib
 *
 * Google Gemini generateContent over HTTPS with server-sent events.
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
import us.apphaus.tokenlib.Usage
import us.apphaus.tokenlib.int
import us.apphaus.tokenlib.list
import us.apphaus.tokenlib.obj
import us.apphaus.tokenlib.str

class GeminiProvider : Provider {
    override val kind = ProviderKind.GEMINI

    override fun request(chat: ChatRequest, call: ProviderCall): HttpRequest {
        val key = call.key?.takeIf { it.isNotEmpty() } ?: throw TokenLibException.MissingKey(ProviderKind.GEMINI)
        val body = linkedMapOf<String, Any?>(
            "contents" to chat.messages.map { mapOf("role" to (if (it.role == ChatMessage.Role.USER) "user" else "model"), "parts" to parts(it)) },
        )
        chat.system?.takeIf { it.isNotEmpty() }?.let { body["systemInstruction"] = mapOf("parts" to listOf(mapOf("text" to it))) }
        val config = linkedMapOf<String, Any?>("maxOutputTokens" to (chat.maxTokens ?: call.maxTokens))
        (chat.temperature ?: call.profile.temperature)?.let { config["temperature"] = it }
        if (chat.jsonSchema != null) config["responseMimeType"] = "application/json"
        body["generationConfig"] = config
        return HttpRequest("$BASE${call.model.id}:streamGenerateContent?alt=sse", headers = mapOf("Content-Type" to "application/json", "x-goog-api-key" to key, "Accept" to "text/event-stream"), body = MiniJson.stringify(body).toByteArray())
    }

    override fun makeParser(): ProviderStreamParser = Parser()

    private class Parser : SseStreamParser() {
        override fun handle(event: SseParser.Event): List<ChatEvent> {
            val json = MiniJson.parse(event.data) ?: return emptyList()
            val out = ArrayList<ChatEvent>()
            json.obj("usageMetadata")?.let { usage = Usage(it.int("promptTokenCount") ?: usage.promptTokens, it.int("candidatesTokenCount") ?: usage.replyTokens) }
            for (candidate in json.list("candidates") ?: emptyList()) {
                for (part in candidate.obj("content").list("parts") ?: emptyList()) part.str("text")?.takeIf { it.isNotEmpty() }?.let { out += ChatEvent.Text(it) }
                candidate.str("finishReason")?.let { stop = when (it) { "MAX_TOKENS" -> StopReason.MAX_TOKENS; "SAFETY" -> StopReason.REFUSAL; else -> StopReason.END } }
            }
            return out
        }
    }

    companion object {
        const val BASE = "https://generativelanguage.googleapis.com/v1beta/models/"

        /** Text parts and `inlineData` image parts. */
        fun parts(message: ChatMessage): List<Map<String, Any?>> = message.contentParts.map { part ->
            when (part) {
                is ChatPart.Text -> mapOf("text" to part.text)
                is ChatPart.Image -> mapOf("inlineData" to mapOf("mimeType" to part.mediaType, "data" to part.data))
            }
        }
    }
}
