/*
 * TokenClient.kt
 * TokenLib
 *
 * The client SDK: what a library or a screen holds. It knows a broker and
 * nothing else; sessions carry a consumer name, a profile and an optional
 * budget of their own.
 */
package us.apphaus.tokenlib

class TokenClient(val broker: TokenBroker) {
    val isReady: Boolean get() = broker.isReady

    /**
     * Opens a session for `consumer` (an actor id, a screen) on a profile. `budget` caps the tokens the
     * session may spend in total; the broker's daily cap applies on top.
     */
    fun session(consumer: String, profile: Profile, budget: Int? = null) = TokenSession(this, consumer, profile, budget)
}

class TokenSession internal constructor(val client: TokenClient, val consumer: String, val profile: Profile, val budget: Int?) {
    var spent = 0
        private set
    var requests = 0
        private set

    val remaining: Int? get() = budget?.let { maxOf(0, it - spent) }
    val isExhausted: Boolean get() = remaining?.let { it <= 0 } ?: false

    /** Streams a reply: `onText` gets deltas as they arrive, `completion` the whole reply with usage. */
    fun stream(request: ChatRequest, onText: (String) -> Unit, completion: (Result<ChatReply>) -> Unit): Cancellable {
        remaining?.let { r -> if (r <= 0 || request.estimatedPromptTokens >= r) { completion(Result.failure(TokenLibException.BudgetExhausted)); return NoopCancellable } }
        return client.broker.stream(request, profile, consumer, onEvent = { if (it is ChatEvent.Text) onText(it.text) }, completion = { result ->
            result.getOrNull()?.let { synchronized(this) { spent += it.usage.total; requests += 1 } }
            completion(result)
        })
    }

    /** A whole reply at once. */
    fun send(request: ChatRequest, completion: (Result<ChatReply>) -> Unit): Cancellable = stream(request, {}, completion)
}
