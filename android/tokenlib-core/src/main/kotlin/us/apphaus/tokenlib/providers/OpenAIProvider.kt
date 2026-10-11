/*
 * OpenAIProvider.kt
 * TokenLib
 *
 * OpenAI chat completions over HTTPS with server-sent events. The same code
 * serves every OpenAI-compatible vendor (DeepSeek, Kimi, Qwen, Grok, Mistral,
 * Cohere, OpenRouter) at its own endpoint, each with a small dialect: which
 * token parameter it takes, whether it takes a temperature, how it reports
 * usage, how it takes a JSON schema and how its reasoning is switched. It
 * also serves LOCAL: an OpenAI-compatible server (Ollama, LM Studio, vLLM) at
 * a base URL from the settings, with no key.
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

class OpenAIProvider(override val kind: ProviderKind = ProviderKind.OPENAI) : Provider {
    /** How a vendor takes a JSON schema. */
    enum class Structured {
        /** `response_format: json_schema`, enforced by the vendor. */
        SCHEMA,
        /** `response_format: json_object` with the schema appended to the system prompt (these APIs also require the prompt to mention JSON). */
        OBJECT,
        /** Cohere's `response_format: {type: json_object, schema}`. */
        OBJECT_WITH_SCHEMA,
    }

    /** The vendor's variations on the chat completions request. */
    class Dialect(
        /** The hosted endpoint; `null` for LOCAL, whose base URL comes from the settings. */
        val endpoint: String?,
        /** `max_completion_tokens` where `max_tokens` is retired, `max_tokens` elsewhere. */
        val maxTokensKey: String,
        /** Whether the vendor takes sampling parameters (OpenAI's current models reject them; Kimi fixes them per model; OpenRouter's depend on the model). */
        val temperature: Boolean,
        /** Whether to ask for usage in the stream with `stream_options.include_usage` (OpenRouter always sends it; Cohere does not document it). */
        val streamUsage: Boolean,
        val structured: Structured,
        /** Extra body fields that set the vendor's reasoning from the profile's effort (`low` or `high`) for a model id; empty when the vendor has no switch. */
        val reasoning: (effort: String, modelId: String) -> Map<String, Any?>,
    )

    override fun request(chat: ChatRequest, call: ProviderCall): HttpRequest {
        val dialect = dialect(kind)
        var system = chat.system ?: ""
        val body = linkedMapOf<String, Any?>("model" to call.model.id, "stream" to true)
        if (dialect.streamUsage) body["stream_options"] = mapOf("include_usage" to true)
        body[dialect.maxTokensKey] = chat.maxTokens ?: call.maxTokens
        if (dialect.temperature) (chat.temperature ?: call.profile.temperature)?.let { body["temperature"] = it }
        call.profile.effort?.let { effort -> body.putAll(dialect.reasoning(effort, call.model.id)) }
        chat.jsonSchema?.let { schema ->
            when (dialect.structured) {
                Structured.SCHEMA -> body["response_format"] = mapOf("type" to "json_schema", "json_schema" to mapOf("name" to "reply", "schema" to schema))
                Structured.OBJECT_WITH_SCHEMA -> body["response_format"] = mapOf("type" to "json_object", "schema" to schema)
                Structured.OBJECT -> {
                    body["response_format"] = mapOf("type" to "json_object")
                    system += (if (system.isEmpty()) "" else "\n\n") + "Reply with a single JSON object that matches this JSON schema: " + MiniJson.stringify(schema)
                }
            }
        }
        val messages = ArrayList<Map<String, Any?>>()
        if (system.isNotEmpty()) messages += mapOf("role" to "system", "content" to system)
        messages += chat.messages.map { mapOf("role" to it.role.id, "content" to content(it)) }
        body["messages"] = messages
        val headers = linkedMapOf("Content-Type" to "application/json", "Accept" to "text/event-stream")
        val url = if (kind == ProviderKind.LOCAL) {
            (call.baseUrl ?: throw TokenLibException.Transport("no local server URL")).trimEnd('/') + "/chat/completions"
        } else {
            val key = call.key?.takeIf { it.isNotEmpty() } ?: throw TokenLibException.MissingKey(kind)
            headers["Authorization"] = "Bearer $key"
            dialect.endpoint ?: throw TokenLibException.Transport("no endpoint for ${kind.id}")
        }
        return HttpRequest(url, headers = headers, body = MiniJson.stringify(body).toByteArray())
    }

    override fun makeParser(): ProviderStreamParser = Parser()

    private class Parser : SseStreamParser() {
        override fun handle(event: SseParser.Event): List<ChatEvent> {
            if (event.data == "[DONE]") { finished = true; return listOf(ChatEvent.Done(usage, stop)) }
            val json = MiniJson.parse(event.data) ?: return emptyList()
            val out = ArrayList<ChatEvent>()
            json.obj("usage")?.let { usage = Usage(it.int("prompt_tokens") ?: usage.promptTokens, it.int("completion_tokens") ?: usage.replyTokens) }
            for (choice in json.list("choices") ?: emptyList()) {
                choice.obj("delta").str("content")?.takeIf { it.isNotEmpty() }?.let { out += ChatEvent.Text(it) }
                choice.str("finish_reason")?.let { stop = when (it) { "length" -> StopReason.MAX_TOKENS; "content_filter" -> StopReason.REFUSAL; else -> StopReason.END } }
            }
            return out
        }
    }

    companion object {
        const val ENDPOINT = "https://api.openai.com/v1/chat/completions"
        const val DEEPSEEK_ENDPOINT = "https://api.deepseek.com/chat/completions"
        const val KIMI_ENDPOINT = "https://api.moonshot.ai/v1/chat/completions"
        const val QWEN_ENDPOINT = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions"
        const val GROK_ENDPOINT = "https://api.x.ai/v1/chat/completions"
        const val MISTRAL_ENDPOINT = "https://api.mistral.ai/v1/chat/completions"
        const val COHERE_ENDPOINT = "https://api.cohere.com/compatibility/v1/chat/completions"
        const val OPENROUTER_ENDPOINT = "https://openrouter.ai/api/v1/chat/completions"

        private val none: (String, String) -> Map<String, Any?> = { _, _ -> emptyMap() }

        fun dialect(kind: ProviderKind): Dialect = when (kind) {
            ProviderKind.OPENAI -> Dialect(ENDPOINT, "max_completion_tokens", temperature = false, streamUsage = true, structured = Structured.SCHEMA, reasoning = none)
            // Thinking is on by default; low effort turns it off.
            ProviderKind.DEEPSEEK -> Dialect(DEEPSEEK_ENDPOINT, "max_tokens", temperature = true, streamUsage = true, structured = Structured.OBJECT) { effort, _ ->
                mapOf("thinking" to (if (effort == "low") mapOf("type" to "disabled") else mapOf("type" to "enabled", "reasoning_effort" to effort)))
            }
            // K3 takes reasoning_effort; K2 has a thinking switch.
            ProviderKind.KIMI -> Dialect(KIMI_ENDPOINT, "max_completion_tokens", temperature = false, streamUsage = true, structured = Structured.SCHEMA) { effort, id ->
                if (id.startsWith("kimi-k3")) mapOf("reasoning_effort" to effort) else mapOf("thinking" to mapOf("type" to (if (effort == "low") "disabled" else "enabled")))
            }
            ProviderKind.QWEN -> Dialect(QWEN_ENDPOINT, "max_tokens", temperature = true, streamUsage = true, structured = Structured.OBJECT) { effort, _ ->
                mapOf("enable_thinking" to (effort != "low"))
            }
            // Grok 4 reasons always; the effort scales it.
            ProviderKind.GROK -> Dialect(GROK_ENDPOINT, "max_tokens", temperature = true, streamUsage = true, structured = Structured.SCHEMA) { effort, _ ->
                mapOf("reasoning_effort" to effort)
            }
            ProviderKind.MISTRAL -> Dialect(MISTRAL_ENDPOINT, "max_tokens", temperature = true, streamUsage = true, structured = Structured.SCHEMA) { effort, _ ->
                mapOf("reasoning_effort" to (if (effort == "low") "none" else "high"))
            }
            // Only the reasoning models take the switch, and only `none` or `high`.
            ProviderKind.COHERE -> Dialect(COHERE_ENDPOINT, "max_tokens", temperature = true, streamUsage = false, structured = Structured.OBJECT_WITH_SCHEMA) { effort, id ->
                if (id.startsWith("command-a-plus") || id.startsWith("command-a-reasoning")) mapOf("reasoning_effort" to (if (effort == "low") "none" else "high")) else emptyMap()
            }
            ProviderKind.OPENROUTER -> Dialect(OPENROUTER_ENDPOINT, "max_tokens", temperature = false, streamUsage = false, structured = Structured.SCHEMA) { effort, _ ->
                mapOf("reasoning" to (if (effort == "low") mapOf("enabled" to false) else mapOf("effort" to effort)))
            }
            else -> Dialect(null, "max_tokens", temperature = true, streamUsage = true, structured = Structured.SCHEMA, reasoning = none)
        }

        /** The hosted endpoint for a kind; `null` for LOCAL. */
        fun endpoint(kind: ProviderKind): String? = dialect(kind).endpoint

        /** A plain string for text-only messages; text and `image_url` data-URI parts otherwise. */
        fun content(message: ChatMessage): Any = if (message.parts == null) message.text else message.contentParts.map { part ->
            when (part) {
                is ChatPart.Text -> mapOf("type" to "text", "text" to part.text)
                is ChatPart.Image -> mapOf("type" to "image_url", "image_url" to mapOf("url" to "data:${part.mediaType};base64,${part.data}"))
            }
        }
    }
}
