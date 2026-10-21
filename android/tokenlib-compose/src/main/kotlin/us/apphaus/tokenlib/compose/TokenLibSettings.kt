/*
 * TokenLibSettings.kt
 * TokenLib (Compose)
 *
 * The settings a host app drops into its own Column: the master switch,
 * provider, key, local server, prompt logging, today's usage. Material 3 controls in the host's
 * theme, no navigation or branding of its own. Keys go straight to the
 * server, which stores ciphertext.
 */
package us.apphaus.tokenlib.compose

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.ProvideTextStyle
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import us.apphaus.tokenlib.Profile
import us.apphaus.tokenlib.ProviderKind
import us.apphaus.tokenlib.UsageTotals
import java.text.DateFormat
import java.util.Date

/** The master switch, provider, key, local server, prompt logging and today's usage. Pass `title = null` to leave the heading to the host. */
@Composable
fun TokenLibSettings(model: TokenLibModel, modifier: Modifier = Modifier, title: String? = "AI provider") {
    LaunchedEffect(model) { model.refresh() }
    Column(modifier) {
        if (title != null) Text(title.uppercase(), style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(bottom = 8.dp))
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("Enable AI", Modifier.weight(1f))
            Switch(checked = model.isEnabled, onCheckedChange = { on -> model.setEnabled(on) })
        }
        if (model.isEnabled) Configuration(model)
        else Text("AI is off: nothing is sent to any provider. Keys and settings are kept.", style = MaterialTheme.typography.bodySmall)
        model.lastError?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error) }
    }
}

/** Everything below the switch: provider, its key or server or availability, activation, logging, today's usage. */
@Composable
private fun Configuration(model: TokenLibModel) {
    var provider by remember { mutableStateOf(model.settings.activeProvider ?: model.availableProviders[0]) }
    var key by remember { mutableStateOf("") }
    var credit by remember { mutableStateOf("") }
    var localUrl by remember { mutableStateOf(model.settings.localBaseUrl ?: "") }
    var localModel by remember { mutableStateOf(model.settings.localModel ?: "") }
    var menu by remember { mutableStateOf(false) }
    Column {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("Provider", Modifier.weight(1f))
            TextButton(onClick = { menu = true }) { Text(label(provider, model)) }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                for (kind in model.availableProviders) DropdownMenuItem(text = { Text(label(kind, model)) }, onClick = { provider = kind; menu = false })
            }
        }
        if (provider.needsKey) {
            OutlinedTextField(value = key, onValueChange = { key = it }, label = { Text(if (model.hasKey(provider)) "API key (stored; enter to replace)" else "API key") },
                singleLine = true, visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth())
            val amount = credit.replace(',', '.').toDoubleOrNull()?.takeIf { it >= 0 }
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(value = credit, onValueChange = { credit = it }, singleLine = true, modifier = Modifier.weight(1f),
                    label = { Text(model.settings.credits[provider]?.let { "≈ $%.2f left; enter a new balance".format(it.remainingUsd) } ?: "Credit balance in $ (optional)") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal))
                TextButton(onClick = { model.setCredit(amount, provider); credit = "" }, enabled = amount != null) { Text("Set") }
            }
        } else if (provider == ProviderKind.LOCAL) {
            OutlinedTextField(value = localUrl, onValueChange = { localUrl = it }, label = { Text("Server URL, e.g. http://192.168.1.20:11434/v1") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(value = localModel, onValueChange = { localModel = it }, label = { Text("Model name, e.g. llama3") }, singleLine = true, modifier = Modifier.fillMaxWidth())
        }
        val active = model.settings.activeProvider == provider && key.isBlank() && (!provider.needsKey || model.hasKey(provider))
        Row(Modifier.fillMaxWidth()) {
            Button(onClick = {
                if (provider == ProviderKind.LOCAL) model.setLocalServer(localUrl, localModel)
                model.activate(provider, key)
                key = ""
            }, enabled = !(provider.needsKey && key.isBlank() && !model.hasKey(provider))) {
                Text(if (active) "Active" else "Use ${provider.displayName}")
            }
            if (model.hasKey(provider)) OutlinedButton(onClick = { model.removeKey(provider) }, modifier = Modifier.padding(start = 8.dp)) { Text("Remove key") }
        }
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("Keep prompts in the usage log", Modifier.weight(1f))
            Switch(checked = model.settings.logPrompts, onCheckedChange = { on -> model.update { it.copy(logPrompts = on) } })
        }
        TokenLibUsageRow("Today", model.usageToday)
        val name = model.modelName(Profile.CHARACTER)
        val reason = model.unavailableReason(provider)
        Text(when {
            reason != null -> reason
            model.isReady && name != null -> "Characters answer with $name."
            else -> "Pick a provider and enter its API key. Keys are stored encrypted on this device. Enter the balance from the provider's billing page to see what is left; it counts this app's use only."
        }, style = MaterialTheme.typography.bodySmall)
    }
}

private fun label(kind: ProviderKind, model: TokenLibModel) = kind.displayName + if (model.hasKey(kind)) " ✓" else ""

/** One line of usage totals. */
@Composable
fun TokenLibUsageRow(label: String, totals: UsageTotals, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth()) {
        Text(label, Modifier.weight(1f))
        Text("%d requests · %d tokens · $%.4f".format(totals.requests, totals.totalTokens, totals.costUsd), style = MaterialTheme.typography.bodySmall)
    }
}

/**
 * What is left, for a main screen: the provider credit the user entered counted down by this app's spend,
 * else tokens remaining under the daily cap, else today's usage (the settings line). The host calls
 * `model.refresh()` after a request.
 */
@Composable
fun TokenLibRemaining(model: TokenLibModel, modifier: Modifier = Modifier) {
    val credit = model.credit
    val cap = model.settings.dailyTokenCap
    val left = model.remainingToday
    when {
        credit != null -> Meter("AI credit left", "≈ $%.2f of $%.2f".format(credit.remainingUsd, credit.totalUsd), credit.remainingMicros.toFloat() / maxOf(credit.micros, 1), modifier)
        cap != null && left != null -> Meter("AI left today", "%,d of %,d tokens".format(left, cap), left.toFloat() / maxOf(cap, 1), modifier)
        else -> ProvideTextStyle(MaterialTheme.typography.bodySmall) { TokenLibUsageRow("AI today", model.usageToday, modifier) }
    }
}

@Composable
private fun Meter(label: String, value: String, fraction: Float, modifier: Modifier) {
    val color = if (fraction > 0) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error
    Column(modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth()) {
            Text(label, Modifier.weight(1f), style = MaterialTheme.typography.bodySmall)
            Text(value, style = MaterialTheme.typography.bodySmall, color = if (fraction > 0) MaterialTheme.colorScheme.onSurfaceVariant else color)
        }
        LinearProgressIndicator(progress = { fraction.coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth().padding(top = 4.dp), color = color)
    }
}

/** Today's and 30-day totals, then recent requests newest first. */
@Composable
fun TokenLibUsage(model: TokenLibModel, modifier: Modifier = Modifier) {
    LaunchedEffect(model) { model.refresh() }
    val time = remember { DateFormat.getTimeInstance(DateFormat.SHORT) }
    LazyColumn(modifier) {
        item {
            TokenLibUsageRow("Today", model.usageToday)
            TokenLibUsageRow("30 days", model.server.usage(System.currentTimeMillis() - 30L * 86_400_000))
            HorizontalDivider(Modifier.padding(vertical = 8.dp))
            Text("RECENT", style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(bottom = 8.dp))
            if (model.recent.isEmpty()) Text("No requests yet", style = MaterialTheme.typography.bodySmall)
        }
        items(model.recent, key = { it.id ?: it.hashCode() }) { row ->
            Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                Row(Modifier.fillMaxWidth()) {
                    Text(row.consumer, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                    Text(time.format(Date(row.at)), style = MaterialTheme.typography.labelSmall)
                }
                Text("%s · %s · %d in, %d out · $%.4f".format(row.model, row.profile.name.lowercase(), row.promptTokens, row.replyTokens, row.costMicros / 1_000_000.0),
                    style = MaterialTheme.typography.bodySmall)
                row.prompt?.let { Text(it, style = MaterialTheme.typography.labelSmall, maxLines = 2) }
            }
        }
        item {
            Spacer(Modifier.width(8.dp))
            OutlinedButton(onClick = { model.clearUsage() }, modifier = Modifier.padding(top = 8.dp)) { Text("Clear usage") }
        }
    }
}

/** A small readiness indicator for a toolbar or a status line. */
@Composable
fun TokenLibStatusBadge(model: TokenLibModel, modifier: Modifier = Modifier) {
    Text(
        if (model.isReady) "AI: ${model.activeProvider?.displayName ?: "ready"}" else if (model.isEnabled) "No AI provider" else "AI off",
        style = MaterialTheme.typography.labelSmall,
        color = if (model.isReady) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = modifier,
    )
}
