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

/**
 * A provider that answers in-process instead of over HTTP (Apple's on-device model on Apple platforms), registered
 * on the server per platform (`TokenServer.nativeProviders`). It streams `ChatEvent`s itself; the server still does
 * the accounting. The core knows the kind (`ProviderKind.APPLE`) and this seam only; no Android platform fills it yet.
 */
interface NativeProvider {
    val kind: ProviderKind
    /** Whether the model can answer right now. */
    val isAvailable: Boolean
    /** Why not, in words for a settings screen; `null` when available. */
    val unavailableReason: String?
    /** Streams the reply as `Text` deltas and ends with `Done`; `completion` then reports success or a [TokenLibException]. */
    fun stream(chat: ChatRequest, call: ProviderCall, onEvent: (ChatEvent) -> Unit, completion: (Result<Unit>) -> Unit): Cancellable
}

object Providers {
    /** The HTTP provider for a kind; native kinds have none ([NativeProvider]). */
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
