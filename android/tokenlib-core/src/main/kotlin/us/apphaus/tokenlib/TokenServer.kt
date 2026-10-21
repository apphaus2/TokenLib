/*
 * TokenServer.kt
 * TokenLib
 *
 * The server side: owns the store, the cipher and the transport, knows the
 * keys, picks the model for a profile, enforces the daily cap and records
 * usage. Apps configure it (keys, active provider) and build their settings
 * screens on its query methods; consumers only ever hold a TokenClient.
 */
package us.apphaus.tokenlib

import java.util.Calendar

/** What consumers see. In-process today; the interface is the seam for a remote broker later. */
interface TokenBroker {
    /** Whether requests can be served right now (a provider is active and, if it needs one, has a key). */
    val isReady: Boolean
    /** Streams a reply. `consumer` names who asked (for usage rows). */
    fun stream(request: ChatRequest, profile: Profile, consumer: String, onEvent: (ChatEvent) -> Unit, completion: (Result<ChatReply>) -> Unit): Cancellable
}

class TokenServer(val store: TokenStore, val cipher: SecretCipher, val transport: HttpTransport = HttpUrlConnectionTransport()) : TokenBroker {
    /** Overrides the catalog's providers (tests inject fakes). */
    val providers = HashMap<ProviderKind, Provider>()
    /** In-process providers by kind, registered per platform; a native kind with no entry here is not offered. */
    val nativeProviders = HashMap<ProviderKind, NativeProvider>()
    /** The start of "today" for the daily cap, epoch milliseconds; midnight local time by default. */
    var dayStart: () -> Long = { Calendar.getInstance().apply { set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0) }.timeInMillis }

    // MARK: - Configuration (the app's settings screens call these)

    val settings: Settings get() = runCatching { store.settings() }.getOrDefault(Settings())

    @Synchronized fun update(change: (Settings) -> Settings) { store.save(change(store.settings())) }

    fun setKey(key: String?, provider: ProviderKind) {
        val trimmed = key?.trim()
        if (trimmed.isNullOrEmpty()) store.setKeyData(null, provider) else store.setKeyData(cipher.encrypt(trimmed.toByteArray(Charsets.UTF_8)), provider)
    }

    fun key(provider: ProviderKind): String? = store.keyData(provider)?.let { String(cipher.decrypt(it), Charsets.UTF_8) }

    fun hasKey(provider: ProviderKind): Boolean = runCatching { store.keyData(provider) != null }.getOrDefault(false)

    val configuredProviders: List<ProviderKind> get() = runCatching { store.providersWithKeys() }.getOrDefault(emptyList())

    /**
     * Moves every stored key from `legacy` to this server's cipher: each key `legacy` can decrypt is
     * re-encrypted with `cipher`, and keys it cannot read are left as they are. Returns the providers whose
     * keys moved. For rotating the cipher key, or moving to a cipher under new identifiers.
     */
    @Synchronized fun reencryptKeys(legacy: SecretCipher): List<ProviderKind> {
        val moved = ArrayList<ProviderKind>()
        for (provider in store.providersWithKeys()) {
            val data = store.keyData(provider) ?: continue
            val plaintext = runCatching { legacy.decrypt(data) }.getOrNull() ?: continue
            store.setKeyData(cipher.encrypt(plaintext), provider)
            moved += provider
        }
        return moved
    }

    /** Whether every stored key decrypts with this server's cipher. */
    val keysReadable: Boolean get() = configuredProviders.all { runCatching { key(it) }.getOrNull() != null }

    /** Picks the provider and stores its key in one step. */
    fun activate(provider: ProviderKind, key: String? = null) {
        if (key != null) setKey(key, provider)
        update { it.copy(activeProvider = provider) }
    }

    /** Turns every request on or off; `Settings.enabled` underneath. */
    fun setEnabled(on: Boolean) = update { it.copy(enabled = on) }

    val isEnabled: Boolean get() = settings.enabled

    override val isReady: Boolean
        get() {
            val s = settings
            if (!s.enabled) return false
            val p = s.activeProvider ?: return false
            return when {
                p.isNative -> nativeProviders[p]?.isAvailable ?: false
                p == ProviderKind.LOCAL -> s.localBaseUrl != null
                else -> hasKey(p)
            }
        }

    /** The kinds a settings screen offers on this device: every HTTP provider, plus the native ones registered here. */
    val availableProviders: List<ProviderKind> get() = ProviderKind.entries.filter { !it.isNative || nativeProviders.containsKey(it) }

    /**
     * Why a native provider cannot answer right now, or that this build has none; `null` for HTTP providers and for
     * a native one that is available.
     */
    fun unavailableReason(kind: ProviderKind): String? {
        if (!kind.isNative) return null
        val native = nativeProviders[kind] ?: return "${kind.displayName} is not available on this platform."
        return native.unavailableReason
    }

    /** The model a profile will run on right now. */
    fun model(profile: Profile): ModelInfo? {
        val p = settings.activeProvider ?: return null
        var m = Catalog.model(profile, p)
        if (p == ProviderKind.LOCAL) settings.localModel?.let { m = m.copy(id = it, name = it) }
        return m
    }

    fun usageToday(): UsageTotals = runCatching { store.totals(dayStart(), null) }.getOrDefault(UsageTotals())
    /** Records the balance the user read off the provider's billing page; spend is counted down from it. `null` or zero forgets it. */
    fun setCredit(micros: Long?, provider: ProviderKind) = update { it.copy(credits = if (micros != null && micros > 0) it.credits + (provider to Credit(micros)) else it.credits - provider) }

    /** The credit entered for a provider (the active one by default) and what is left of it; `null` when none was entered. */
    fun credit(provider: ProviderKind? = null): Credit? = settings.let { s -> (provider ?: s.activeProvider)?.let { s.credits[it] } }

    /** Tokens left under the daily cap today; `null` when there is no cap. */
    fun remainingToday(): Int? = settings.dailyTokenCap?.let { maxOf(0, it - usageToday().totalTokens) }
    fun usage(sinceMillis: Long, consumer: String? = null): UsageTotals = runCatching { store.totals(sinceMillis, consumer) }.getOrDefault(UsageTotals())
    fun recentUsage(limit: Int = 50, consumer: String? = null): List<UsageRecord> = runCatching { store.recent(limit, consumer) }.getOrDefault(emptyList())

    // MARK: - TokenBroker

    override fun stream(request: ChatRequest, profile: Profile, consumer: String, onEvent: (ChatEvent) -> Unit, completion: (Result<ChatReply>) -> Unit): Cancellable {
        val settings = this.settings
        if (!settings.enabled) return failed(TokenLibException.Disabled, completion)
        val kind = settings.activeProvider ?: return failed(TokenLibException.NoProvider, completion)
        settings.dailyTokenCap?.let { cap -> if (usageToday().totalTokens + request.estimatedPromptTokens >= cap) return failed(TokenLibException.DailyCapReached, completion) }
        val key = try { key(kind) } catch (e: Exception) { return failed(TokenLibException.Transport(e.message ?: e.toString()), completion) }
        if (kind.needsKey && key == null) return failed(TokenLibException.MissingKey(kind), completion)
        val model = model(profile) ?: return failed(TokenLibException.NoProvider, completion)
        val call = ProviderCall(model, key, settings.localBaseUrl, profile)
        // Everything after the provider answers is the same for both paths: fill in estimates, record usage, charge credit.
        val text = StringBuilder()
        var done: ChatEvent.Done? = null
        val deliver: (ChatEvent) -> Unit = { event ->
            when (event) {
                is ChatEvent.Text -> text.append(event.text)
                is ChatEvent.Done -> if (done == null) done = event
            }
            onEvent(event)
        }
        val finish: (Result<Unit>) -> Unit = { result ->
            result.fold(onFailure = { completion(Result.failure(it)) }, onSuccess = {
                val reply = text.toString()
                var usage = done?.usage ?: Usage()
                val stop = done?.stop ?: StopReason.OTHER
                if (usage.promptTokens == 0) usage = usage.copy(promptTokens = request.estimatedPromptTokens)
                if (usage.replyTokens == 0) usage = usage.copy(replyTokens = (reply.toByteArray(Charsets.UTF_8).size + 3) / 4)
                runCatching {
                    val cost = model.costMicros(usage.promptTokens, usage.replyTokens)
                    store.record(UsageRecord(consumer = consumer, profile = profile, provider = kind, model = model.id, promptTokens = usage.promptTokens, replyTokens = usage.replyTokens,
                        costMicros = cost, stop = stop,
                        prompt = if (settings.logPrompts) request.messages.lastOrNull()?.text else null, reply = if (settings.logPrompts) reply else null))
                    if (cost > 0 && settings.credits[kind] != null) update { s -> s.credits[kind]?.let { c -> s.copy(credits = s.credits + (kind to c.copy(spentMicros = c.spentMicros + cost))) } ?: s }
                }
                completion(Result.success(ChatReply(reply, usage, stop, model.id, kind)))
            })
        }
        if (kind.isNative) {
            val native = nativeProviders[kind]?.takeIf { it.isAvailable } ?: return failed(TokenLibException.Unavailable(kind), completion)
            return native.stream(request, call, deliver, finish)
        }
        val provider = providers[kind] ?: Providers.provider(kind)
        val http = try { provider.request(request, call) } catch (e: TokenLibException) { return failed(e, completion) } catch (e: Exception) { return failed(TokenLibException.Transport(e.message ?: e.toString()), completion) }
        val parser = provider.makeParser()
        return transport.stream(http, onStatus = {}, onLine = { line -> parser.feed(line).forEach(deliver) }, completion = { result ->
            if (result.isSuccess) parser.finish().forEach(deliver)
            finish(result)
        })
    }

    private fun failed(error: TokenLibException, completion: (Result<ChatReply>) -> Unit): Cancellable { completion(Result.failure(error)); return NoopCancellable }
}
