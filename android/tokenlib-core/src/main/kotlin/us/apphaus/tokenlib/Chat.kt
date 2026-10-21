/*
 * Chat.kt
 * TokenLib
 *
 * The request and the streamed reply, in TokenLib's own terms. Providers
 * translate these to their wire formats; consumers never see a provider.
 */
package us.apphaus.tokenlib

/** One piece of a message: text, or an image carried inline as base64. */
sealed class ChatPart {
    data class Text(val text: String) : ChatPart()
    /** `mediaType` is the MIME type (`image/jpeg`, `image/png`, `image/webp`, `image/gif`); `data` is base64 with no `data:` prefix. */
    data class Image(val data: String, val mediaType: String) : ChatPart()

    companion object {
        fun joinedText(parts: List<ChatPart>): String = parts.filterIsInstance<Text>().joinToString("\n") { it.text }
    }
}

data class ChatMessage(
    val role: Role,
    /** Plain text; when `parts` is set this is the concatenated text, kept for logging and estimates. */
    val text: String,
    /** Multimodal content; `null` means the message is `text` alone. */
    val parts: List<ChatPart>? = null,
) {
    enum class Role(val id: String) { USER("user"), ASSISTANT("assistant") }

    /** The parts providers send: `parts` when set, else the text alone. */
    val contentParts: List<ChatPart> get() = parts ?: listOf(ChatPart.Text(text))
    val imageCount: Int get() = parts?.count { it is ChatPart.Image } ?: 0

    companion object {
        fun user(text: String) = ChatMessage(Role.USER, text)
        fun assistant(text: String) = ChatMessage(Role.ASSISTANT, text)
        /** A user message made of text and image parts. */
        fun user(parts: List<ChatPart>) = ChatMessage(Role.USER, ChatPart.joinedText(parts), parts)
    }
}

data class ChatRequest(
    val system: String? = null,
    val messages: List<ChatMessage>,
    /** Overrides the profile's defaults when set. */
    val maxTokens: Int? = null,
    val temperature: Double? = null,
    /**
     * Ask the provider for a reply that validates against this JSON schema (Anthropic `output_config.format`,
     * OpenAI `response_format`, Gemini `responseMimeType`). The reply text is then the JSON document.
     * Providers that cannot enforce the schema still ask for JSON.
     */
    val jsonSchema: Map<String, Any?>? = null,
) {
    /** Roughly four characters per token, plus about 1,600 per image; used before a request to check budgets. */
    val estimatedPromptTokens: Int
        get() {
            val chars = (system?.toByteArray(Charsets.UTF_8)?.size ?: 0) + messages.sumOf { it.text.toByteArray(Charsets.UTF_8).size + 8 }
            val images = messages.sumOf { it.imageCount }
            return (chars + 3) / 4 + images * 1600
        }
}

data class Usage(val promptTokens: Int = 0, val replyTokens: Int = 0) {
    val total: Int get() = promptTokens + replyTokens
}

enum class StopReason(val id: String) {
    END("end"), MAX_TOKENS("maxTokens"), REFUSAL("refusal"), OTHER("other");
    companion object { fun of(id: String?): StopReason = entries.firstOrNull { it.id == id } ?: OTHER }
}

/** What a provider emits while a reply streams. */
sealed class ChatEvent {
    data class Text(val text: String) : ChatEvent()
    data class Done(val usage: Usage, val stop: StopReason) : ChatEvent()
}

/** The reply; `model` and `provider` say what answered, for the consumer's records (consumers still never choose them). */
data class ChatReply(val text: String, val usage: Usage, val stop: StopReason, val model: String, val provider: ProviderKind)

sealed class TokenLibException(message: String) : Exception(message) {
    /** `Settings.enabled` is off: nothing is sent anywhere. */
    object Disabled : TokenLibException("AI is turned off")
    object NoProvider : TokenLibException("no AI provider is configured")
    data class MissingKey(val provider: ProviderKind) : TokenLibException("no API key for ${provider.displayName}")
    /** A native provider (Apple Intelligence) is active but cannot answer on this device or build. */
    data class Unavailable(val provider: ProviderKind) : TokenLibException("${provider.displayName} is not available on this device")
    object BudgetExhausted : TokenLibException("the session's token budget is spent")
    object DailyCapReached : TokenLibException("the daily token cap is reached")
    data class Http(val status: Int, val body: String) : TokenLibException("HTTP $status: ${body.take(200)}")
    data class Transport(val reason: String) : TokenLibException("transport: $reason")
    data class Malformed(val reason: String) : TokenLibException("malformed reply: $reason")
    object Cancelled : TokenLibException("cancelled")
}
