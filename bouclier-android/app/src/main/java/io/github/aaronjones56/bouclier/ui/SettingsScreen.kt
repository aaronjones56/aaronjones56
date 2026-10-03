package io.github.aaronjones56.bouclier.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.BatteryChargingFull
import androidx.compose.material.icons.outlined.Block
import androidx.compose.material.icons.outlined.Dns
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.Palette
import androidx.compose.material.icons.outlined.PowerSettingsNew
import androidx.compose.material.icons.outlined.Update
import androidx.compose.material.icons.outlined.VpnLock
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.aaronjones56.bouclier.BuildConfig
import io.github.aaronjones56.bouclier.data.DnsProvider
import io.github.aaronjones56.bouclier.data.Settings
import io.github.aaronjones56.bouclier.data.SettingsRepository
import io.github.aaronjones56.bouclier.data.ThemeMode
import io.github.aaronjones56.bouclier.net.BlockResponse
import io.github.aaronjones56.bouclier.ui.components.ClickRow
import io.github.aaronjones56.bouclier.ui.components.ScreenHeader
import io.github.aaronjones56.bouclier.ui.components.SectionTitle
import io.github.aaronjones56.bouclier.ui.components.SwitchRow
import io.github.aaronjones56.bouclier.util.SystemSettings

private val BlockResponse.title: String
    get() = when (this) {
        BlockResponse.NULL_IP -> "Adresse nulle (0.0.0.0)"
        BlockResponse.NXDOMAIN -> "Domaine inexistant (NXDOMAIN)"
    }

private val BlockResponse.detail: String
    get() = when (this) {
        BlockResponse.NULL_IP -> "Recommandé : les applications abandonnent tout de suite."
        BlockResponse.NXDOMAIN -> "Certaines applications réessaient alors plusieurs fois."
    }

@Composable
fun SettingsScreen(onMessage: (String) -> Unit) {
    val context = LocalContext.current
    val settings by SettingsRepository.state.collectAsStateWithLifecycle()
    var showDnsDialog by rememberSaveable { mutableStateOf(false) }
    var showBlockDialog by rememberSaveable { mutableStateOf(false) }
    var showThemeDialog by rememberSaveable { mutableStateOf(false) }
    var batteryExempt by remember { mutableStateOf(SystemSettings.isIgnoringBatteryOptimizations(context)) }
    LifecycleResumeEffect(Unit) {
        batteryExempt = SystemSettings.isIgnoringBatteryOptimizations(context)
        onPauseOrDispose { }
    }

    LazyColumn(Modifier.fillMaxSize()) {
        item { ScreenHeader(title = "Paramètres") }

        item { SectionTitle("Général") }
        item {
            SwitchRow(
                title = "Démarrer avec le téléphone",
                subtitle = "Réactive la protection après un redémarrage",
                checked = settings.startOnBoot,
                onCheckedChange = { value -> SettingsRepository.update { it.copy(startOnBoot = value) } },
                icon = Icons.Outlined.PowerSettingsNew,
            )
        }
        item {
            SwitchRow(
                title = "Mise à jour automatique des listes",
                subtitle = "Tous les deux jours, en Wi-Fi uniquement",
                checked = settings.autoUpdate,
                onCheckedChange = { value -> SettingsRepository.update { it.copy(autoUpdate = value) } },
                icon = Icons.Outlined.Update,
            )
        }

        item { SectionTitle("Filtrage DNS") }
        item {
            ClickRow(
                title = "Serveur DNS",
                subtitle = when (settings.dnsProvider) {
                    DnsProvider.CUSTOM -> "Personnalisé : ${settings.customDns}"
                    else -> "${settings.dnsProvider.title} · ${settings.dnsProvider.detail}"
                },
                onClick = { showDnsDialog = true },
                icon = Icons.Outlined.Dns,
            )
        }
        item {
            ClickRow(
                title = "Réponse aux domaines bloqués",
                subtitle = settings.blockResponse.title,
                onClick = { showBlockDialog = true },
                icon = Icons.Outlined.Block,
            )
        }

        item { SectionTitle("Android") }
        item {
            ClickRow(
                title = "VPN permanent",
                subtitle = "Choisissez Bouclier et activez « VPN permanent » : Android relancera la protection tout seul.",
                onClick = { SystemSettings.openVpnSettings(context) },
                icon = Icons.Outlined.VpnLock,
            )
        }
        item {
            ClickRow(
                title = "Optimisation de la batterie",
                subtitle = if (batteryExempt) {
                    "Désactivée pour Bouclier : la protection ne sera pas coupée."
                } else {
                    "Active : Android peut couper la protection. Touchez pour l'en empêcher."
                },
                onClick = { SystemSettings.requestIgnoreBatteryOptimizations(context) },
                icon = Icons.Outlined.BatteryChargingFull,
            )
        }
        item {
            ClickRow(
                title = "Notifications",
                subtitle = "Gérer la notification de protection",
                onClick = { SystemSettings.openNotificationSettings(context) },
                icon = Icons.Outlined.Notifications,
            )
        }

        item { SectionTitle("Apparence") }
        item {
            ClickRow(
                title = "Thème",
                subtitle = settings.theme.title,
                onClick = { showThemeDialog = true },
                icon = Icons.Outlined.Palette,
            )
        }

        item { SectionTitle("À propos") }
        item { About() }
    }

    if (showDnsDialog) {
        DnsDialog(
            current = settings,
            onDismiss = { showDnsDialog = false },
            onSave = { provider, custom ->
                SettingsRepository.update { it.copy(dnsProvider = provider, customDns = custom) }
                showDnsDialog = false
                onMessage("Serveur DNS : ${provider.title}")
            },
        )
    }
    if (showBlockDialog) {
        ChoiceDialog(
            title = "Réponse aux domaines bloqués",
            options = BlockResponse.entries,
            selected = settings.blockResponse,
            label = { it.title },
            detail = { it.detail },
            onSelect = { choice ->
                SettingsRepository.update { it.copy(blockResponse = choice) }
                showBlockDialog = false
            },
            onDismiss = { showBlockDialog = false },
        )
    }
    if (showThemeDialog) {
        ChoiceDialog(
            title = "Thème",
            options = ThemeMode.entries,
            selected = settings.theme,
            label = { it.title },
            detail = { null },
            onSelect = { choice ->
                SettingsRepository.update { it.copy(theme = choice) }
                showThemeDialog = false
            },
            onDismiss = { showThemeDialog = false },
        )
    }
}

@Composable
private fun About() {
    Column(Modifier.padding(horizontal = 20.dp, vertical = 8.dp)) {
        Text("Bouclier ${BuildConfig.VERSION_NAME}", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(6.dp))
        Text(
            "Bloqueur de publicités et de traqueurs par filtrage DNS. Tout se passe sur votre téléphone : " +
                "Bouclier n'envoie aucune donnée à un serveur qui lui appartiendrait. Seules les requêtes DNS " +
                "autorisées partent vers le serveur DNS choisi, comme sans Bouclier.",
            style = MaterialTheme.typography.bodyMedium,
        )
        Spacer(Modifier.height(10.dp))
        Text(
            "Listes de filtres : AdGuard DNS filter (GPL-3.0), HaGeZi DNS Blocklists (GPL-3.0), " +
                "StevenBlack hosts (MIT) et malware-filter. Merci à leurs auteurs. Bouclier est un projet " +
                "indépendant, sans lien avec ces projets ni avec AdGuard.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun DnsDialog(current: Settings, onDismiss: () -> Unit, onSave: (DnsProvider, String) -> Unit) {
    var provider by rememberSaveable { mutableStateOf(current.dnsProvider) }
    var custom by rememberSaveable { mutableStateOf(current.customDns) }
    val customValid = provider != DnsProvider.CUSTOM || Settings(customDns = custom).customDnsAddresses.isNotEmpty()
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Serveur DNS") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                Text(
                    "Les requêtes autorisées sont transmises à ce serveur pour obtenir l'adresse des sites.",
                    style = MaterialTheme.typography.bodyMedium,
                )
                Spacer(Modifier.height(8.dp))
                DnsProvider.entries.forEach { option ->
                    ChoiceRow(
                        label = option.title,
                        detail = option.detail,
                        selected = provider == option,
                        onClick = { provider = option },
                    )
                }
                if (provider == DnsProvider.CUSTOM) {
                    OutlinedTextField(
                        value = custom,
                        onValueChange = { custom = it },
                        label = { Text("Adresses IP, séparées par des virgules") },
                        placeholder = { Text("9.9.9.9, 149.112.112.112") },
                        isError = !customValid,
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        },
        confirmButton = {
            TextButton(onClick = { onSave(provider, custom.trim()) }, enabled = customValid) { Text("Enregistrer") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Annuler") } },
    )
}

@Composable
private fun <T> ChoiceDialog(
    title: String,
    options: List<T>,
    selected: T,
    label: (T) -> String,
    detail: (T) -> String?,
    onSelect: (T) -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column {
                options.forEach { option ->
                    ChoiceRow(label(option), detail(option), selected = option == selected, onClick = { onSelect(option) })
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Fermer") } },
    )
}

@Composable
private fun ChoiceRow(label: String, detail: String?, selected: Boolean, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .selectable(selected = selected, role = Role.RadioButton, onClick = onClick)
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(selected = selected, onClick = null)
        Spacer(Modifier.width(12.dp))
        Column {
            Text(label, style = MaterialTheme.typography.bodyLarge)
            if (detail != null) {
                Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}
