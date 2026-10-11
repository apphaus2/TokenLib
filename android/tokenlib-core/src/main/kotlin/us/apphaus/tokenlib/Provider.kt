/*
 * Provider.kt
 * TokenLib
 *
 * A provider turns a ChatRequest into one HTTP request for its API and
 * turns the streamed body back into ChatEvents. Implementations are plain
 * HTTP: no vendor SDKs, so Swift and Kotlin behave the same.
 */
package us.apphaus.tokenlib

import us.apphaus.tokenlib.providers.AnthropicProvider
import us.apphaus.tokenlib.providers.GeminiProvider
import us.apphaus.tokenlib.providers.OpenAIProvider

data class ProviderCall(val model: ModelInfo, val key: String?, /** For LOCAL: the server's base URL, e.g. `http://192.168.1.20:11434/v1`. */ val baseUrl: String? = null, val profile: Profile) {
    val maxTokens: Int get() = profile.maxTokens
}

interface Provider {
    val kind: ProviderKind
    /** Builds the HTTP request for a streaming reply. */
    fun request(chat: ChatRequest, call: ProviderCall): HttpRequest
    /** A fresh parser for the streamed body of one request. */
    fun makeParser(): ProviderStreamParser
}

/** Consumes body lines and emits chat events. `finish` is called at the end of the body. */
interface ProviderStreamParser {
    fun feed(line: String): List<ChatEvent>
    fun finish(): List<ChatEvent>
}

object Providers {
    fun provider(kind: ProviderKind): Provider = when (kind) {
        ProviderKind.ANTHROPIC -> AnthropicProvider()
        ProviderKind.GEMINI -> GeminiProvider()
        else -> OpenAIProvider(kind)
    }
}

/** Shared shape of the three SSE parsers: usage and stop reason accumulate, `finish` flushes the last event. */
abstract class SseStreamParser : ProviderStreamParser {
    protected val sse = SseParser()
    protected var usage = Usage()
    protected var stop = StopReason.END
    protected var finished = false

    protected abstract fun handle(event: SseParser.Event): List<ChatEvent>

    override fun feed(line: String): List<ChatEvent> = sse.feed(line)?.let { handle(it) } ?: emptyList()

    override fun finish(): List<ChatEvent> {
        // A body that ends without a blank line still holds its last event.
        val out = feed("").toMutableList()
        if (!finished) { finished = true; out += ChatEvent.Done(usage, stop) }
        return out
    }
}
