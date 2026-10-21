/*
 * TokenLibModel.kt
 * TokenLib (Compose)
 *
 * The server as Compose state: settings, configured providers, today's
 * usage, the last error, and the commands a settings screen needs. A host
 * app holds one of these and hands it to TokenLibSettings or its own UI.
 */
package us.apphaus.tokenlib.compose

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import us.apphaus.tokenlib.Credit
import us.apphaus.tokenlib.Profile
import us.apphaus.tokenlib.ProviderKind
import us.apphaus.tokenlib.Settings
import us.apphaus.tokenlib.TokenClient
import us.apphaus.tokenlib.TokenServer
import us.apphaus.tokenlib.UsageRecord
import us.apphaus.tokenlib.UsageTotals
import us.apphaus.tokenlib.android.TokenLib

class TokenLibModel(val server: TokenServer) {
    /** `TokenLib.standard(context)` wrapped in a model. */
    constructor(context: Context, appId: String = context.packageName) : this(TokenLib.standard(context, appId))

    val client = TokenClient(server)

    var settings: Settings by mutableStateOf(server.settings)
        private set
    var configured: List<ProviderKind> by mutableStateOf(emptyList())
        private set
    var usageToday: UsageTotals by mutableStateOf(UsageTotals())
        private set
    /** Tokens left under the daily cap today; `null` when there is no cap. */
    var remainingToday: Int? by mutableStateOf(null)
        private set
    /** The credit entered for the active provider and what is left of it; `null` when none was entered. */
    var credit: Credit? by mutableStateOf(null)
        private set
    var recent: List<UsageRecord> by mutableStateOf(emptyList())
        private set
    var lastError: String? by mutableStateOf(null)

    init { refresh() }

    val isReady: Boolean get() = server.isReady
    val isEnabled: Boolean get() = settings.enabled
    val activeProvider: ProviderKind? get() = settings.activeProvider
    /** The kinds to offer on this device (`TokenServer.availableProviders`). */
    val availableProviders: List<ProviderKind> get() = server.availableProviders
    /** Why a native provider cannot answer right now, for the settings footer; `null` when it can. */
    fun unavailableReason(provider: ProviderKind): String? = server.unavailableReason(provider)

    /** The model a profile runs on right now, for display. */
    fun modelName(profile: Profile): String? = server.model(profile)?.let { "${it.name} (${it.provider.displayName})" }

    fun hasKey(provider: ProviderKind): Boolean = provider in configured

    fun refresh() {
        settings = server.settings
        configured = server.configuredProviders
        usageToday = server.usageToday()
        remainingToday = server.remainingToday()
        credit = server.credit()
        recent = server.recentUsage(20)
    }

    /** Stores the key (when given) and makes the provider active. */
    fun activate(provider: ProviderKind, key: String? = null) = run { server.activate(provider, key?.takeIf { it.isNotBlank() }) }

    fun removeKey(provider: ProviderKind) = run { server.setKey(null, provider) }

    /** The master switch: off means no request is sent anywhere. */
    fun setEnabled(on: Boolean) = run { server.setEnabled(on) }

    fun update(change: (Settings) -> Settings) = run { server.update(change) }

    fun setLocalServer(url: String?, model: String?) = run { server.update { it.copy(localBaseUrl = url?.takeIf { u -> u.isNotBlank() }, localModel = model?.takeIf { m -> m.isNotBlank() }) } }

    /** The balance read off the provider's billing page, in dollars; `null` or zero forgets it. */
    fun setCredit(dollars: Double?, provider: ProviderKind) = run { server.setCredit(dollars?.let { Math.round(it * 1_000_000) }, provider) }

    fun clearUsage() = run { server.store.deleteAll() }

    private fun run(body: () -> Unit) {
        runCatching(body).onSuccess { lastError = null }.onFailure { lastError = it.message ?: it.toString() }
        refresh()
    }
}
