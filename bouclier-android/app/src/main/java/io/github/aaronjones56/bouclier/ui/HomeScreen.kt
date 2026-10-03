package io.github.aaronjones56.bouclier.ui

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material.icons.outlined.BatteryAlert
import androidx.compose.material.icons.outlined.Category
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.PieChart
import androidx.compose.material.icons.outlined.VpnLock
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.aaronjones56.bouclier.data.SettingsRepository
import io.github.aaronjones56.bouclier.filter.FilterCategory
import io.github.aaronjones56.bouclier.filter.FilterListState
import io.github.aaronjones56.bouclier.filter.FilterRepository
import io.github.aaronjones56.bouclier.filter.UpdateResult
import io.github.aaronjones56.bouclier.stats.StatsRepository
import io.github.aaronjones56.bouclier.ui.components.BigToggle
import io.github.aaronjones56.bouclier.ui.components.SyncButton
import io.github.aaronjones56.bouclier.ui.components.icon
import io.github.aaronjones56.bouclier.ui.theme.BouclierTheme
import io.github.aaronjones56.bouclier.util.Format
import io.github.aaronjones56.bouclier.util.SystemSettings
import io.github.aaronjones56.bouclier.vpn.BouclierVpnService
import kotlinx.coroutines.launch

private val HOME_CATEGORIES = listOf(
    FilterCategory.ADS,
    FilterCategory.TRACKERS,
    FilterCategory.SECURITY,
    FilterCategory.SOCIAL,
    FilterCategory.ADULT,
    FilterCategory.GAMBLING,
)

/** Carte de conseil affichée en bas de l'écran d'accueil. */
internal class Tip(
    val id: String,
    val icon: ImageVector,
    val text: String,
    val warning: Boolean = false,
    val dismissible: Boolean = true,
    val onClick: () -> Unit,
)

@Composable
fun HomeScreen(controller: ProtectionController, onNavigate: (Tab) -> Unit, onMessage: (String) -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val vpnState by BouclierVpnService.state.collectAsStateWithLifecycle()
    val lists by FilterRepository.lists.collectAsStateWithLifecycle()
    val matcher by FilterRepository.matcher.collectAsStateWithLifecycle()
    val updating by FilterRepository.updating.collectAsStateWithLifecycle()
    val settings by SettingsRepository.state.collectAsStateWithLifecycle()
    val stats by remember { StatsRepository.snapshots(1000) }
        .collectAsStateWithLifecycle(initialValue = remember { StatsRepository.snapshot() })

    var privateDns by remember { mutableStateOf<String?>(null) }
    var batteryOptimized by remember { mutableStateOf(false) }
    LifecycleResumeEffect(Unit) {
        privateDns = SystemSettings.privateDnsHostname(context)
        batteryOptimized = !SystemSettings.isIgnoringBatteryOptimizations(context)
        onPauseOrDispose { }
    }
    var showHelp by rememberSaveable { mutableStateOf(false) }

    val tips = buildList {
        if (privateDns != null) {
            add(Tip("private_dns", Icons.Outlined.WarningAmber, "Le DNS privé empêche le blocage. Touchez pour corriger.", warning = true, dismissible = false) { showHelp = true })
        }
        add(Tip("missed_ads", Icons.Outlined.Info, "Des publicités passent encore ? Voici comment y remédier.", warning = true) { showHelp = true })
        add(Tip("stats", Icons.Outlined.PieChart, "Voyez ce qui a été bloqué aujourd'hui.") { onNavigate(Tab.STATS) })
        if (batteryOptimized) {
            add(Tip("battery", Icons.Outlined.BatteryAlert, "Empêchez Android de couper la protection.") {
                SystemSettings.requestIgnoreBatteryOptimizations(context)
            })
        }
        add(Tip("always_on", Icons.Outlined.VpnLock, "Activez le VPN permanent pour une protection continue.") {
            SystemSettings.openVpnSettings(context)
        })
        add(Tip("apps", Icons.Outlined.Category, "Une appli ne marche plus ? Excluez-la du filtrage.") { onNavigate(Tab.APPS) })
    }.filter { !it.dismissible || it.id !in settings.dismissedTips }

    HomeContent(
        running = vpnState == BouclierVpnService.State.RUNNING,
        starting = vpnState == BouclierVpnService.State.STARTING,
        lists = lists,
        usingBuiltinList = matcher.usingBuiltinList,
        blockedDomainCount = matcher.blockedDomainCount,
        updating = updating,
        todayBlocked = stats.todayBlocked,
        tips = tips,
        onToggle = controller::setEnabled,
        onSync = { scope.launch { onMessage(updateMessage(FilterRepository.update(force = true))) } },
        onOpenProtection = { onNavigate(Tab.PROTECTION) },
        onDismissTip = SettingsRepository::dismissTip,
    )

    if (showHelp) {
        MissedAdsDialog(privateDns = privateDns, onDismiss = { showHelp = false })
    }
}

/** Contenu de l'écran d'accueil, sans état propre (affichable tel quel dans les tests). */
@Composable
internal fun HomeContent(
    running: Boolean,
    starting: Boolean,
    lists: List<FilterListState>,
    usingBuiltinList: Boolean,
    blockedDomainCount: Int,
    updating: Boolean,
    todayBlocked: Int,
    tips: List<Tip>,
    onToggle: (Boolean) -> Unit,
    onSync: () -> Unit,
    onOpenProtection: () -> Unit,
    onDismissTip: (String) -> Unit,
) {
    val colors = BouclierTheme.colors
    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier
                .fillMaxWidth()
                .padding(start = 20.dp, end = 8.dp, top = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Filled.VerifiedUser, contentDescription = null, tint = colors.accent, modifier = Modifier.size(34.dp))
            Spacer(Modifier.width(8.dp))
            Text("bouclier", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
            Spacer(Modifier.weight(1f))
            SyncButton(updating = updating, onClick = onSync)
        }
        Spacer(Modifier.height(24.dp))
        CategoryRow(lists = lists, active = running, onClick = onOpenProtection)
        Spacer(Modifier.height(32.dp))
        Text(
            text = when {
                running -> "La protection est activée"
                starting -> "Démarrage de la protection…"
                else -> "La protection est désactivée"
            },
            style = MaterialTheme.typography.headlineMedium,
            fontWeight = FontWeight.Bold,
            textAlign = TextAlign.Center,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 24.dp),
        )
        Spacer(Modifier.height(10.dp))
        Text(
            text = statusLine(running, todayBlocked, usingBuiltinList, blockedDomainCount, updating),
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 32.dp),
        )
        Spacer(Modifier.weight(1f))
        BigToggle(
            checked = running || starting,
            onCheckedChange = onToggle,
            modifier = Modifier.align(Alignment.CenterHorizontally),
        )
        Spacer(Modifier.weight(1f))
        // Rangée défilante de cartes, toutes à la hauteur de la plus haute.
        Row(
            Modifier
                .horizontalScroll(rememberScrollState())
                .height(IntrinsicSize.Max)
                .padding(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            tips.forEach { tip ->
                key(tip.id) {
                    TipCard(tip, onDismiss = { onDismissTip(tip.id) })
                }
            }
        }
        Spacer(Modifier.height(16.dp))
    }
}

private fun statusLine(
    running: Boolean,
    todayBlocked: Int,
    usingBuiltinList: Boolean,
    blockedDomainCount: Int,
    updating: Boolean,
): String {
    if (!running) return "Activez la protection pour bloquer les publicités et les traqueurs dans toutes vos applications."
    val first = "${Format.count(todayBlocked)} ${if (todayBlocked > 1) "requêtes bloquées" else "requête bloquée"} aujourd'hui"
    val second = when {
        usingBuiltinList && updating -> "Téléchargement des listes de filtres…"
        usingBuiltinList -> "Listes de filtres pas encore téléchargées"
        else -> "${Format.count(blockedDomainCount)} domaines surveillés"
    }
    return "$first\n$second"
}

/** Message affiché après une mise à jour manuelle des listes. */
internal fun updateMessage(result: UpdateResult): String = when {
    result.checked == 0 -> "Aucune liste de filtres activée"
    result.failed == 0 -> "Listes de filtres à jour"
    result.updated == 0 -> "Mise à jour impossible : vérifiez votre connexion"
    else -> "${result.updated} liste(s) mise(s) à jour, ${result.failed} en échec"
}

@Composable
private fun CategoryRow(lists: List<FilterListState>, active: Boolean, onClick: () -> Unit) {
    val colors = BouclierTheme.colors
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp),
        horizontalArrangement = Arrangement.SpaceEvenly,
    ) {
        HOME_CATEGORIES.forEach { category ->
            val enabled = lists.any { it.info.category == category && it.enabled }
            val tint by animateColorAsState(if (enabled && active) colors.accent else colors.inactiveIcon, label = category.name)
            Icon(
                category.icon,
                contentDescription = "${category.title} : ${if (enabled) "bloqué" else "non bloqué"}",
                tint = tint,
                modifier = Modifier
                    .size(52.dp)
                    .clip(CircleShape)
                    .clickable(onClick = onClick)
                    .padding(8.dp),
            )
        }
    }
}

@Composable
private fun TipCard(tip: Tip, onDismiss: () -> Unit) {
    val colors = BouclierTheme.colors
    val shape = RoundedCornerShape(16.dp)
    Column(
        Modifier
            .width(172.dp)
            .fillMaxHeight()
            .heightIn(min = 156.dp)
            .clip(shape)
            .background(if (tip.warning) colors.warningContainer else colors.card)
            .then(if (tip.warning) Modifier.border(1.dp, colors.warningBorder, shape) else Modifier)
            .clickable(onClick = tip.onClick)
            .padding(start = 16.dp, top = 8.dp, end = 4.dp, bottom = 14.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.heightIn(min = 48.dp)) {
            Icon(
                tip.icon,
                contentDescription = null,
                tint = if (tip.warning) colors.warningIcon else colors.accent,
                modifier = Modifier.size(30.dp),
            )
            Spacer(Modifier.weight(1f))
            if (tip.dismissible) {
                TextButton(onClick = onDismiss) {
                    Text("Masquer", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
        Spacer(Modifier.height(6.dp))
        Text(
            tip.text,
            style = MaterialTheme.typography.bodyLarge,
            maxLines = 5,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(end = 12.dp),
        )
    }
}

@Composable
private fun MissedAdsDialog(privateDns: String?, onDismiss: () -> Unit) {
    val context = LocalContext.current
    AlertDialog(
        onDismissRequest = onDismiss,
        icon = { Icon(Icons.Outlined.Info, contentDescription = null) },
        title = { Text("Publicités non bloquées") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                HelpSection(
                    "DNS privé",
                    if (privateDns != null) {
                        "Le DNS privé est réglé sur « $privateDns » : vos requêtes partent chiffrées vers ce serveur et " +
                            "contournent Bouclier. Dans Réglages › Réseau et Internet › DNS privé, choisissez " +
                            "« Automatique » ou « Désactivé »."
                    } else {
                        "Si le DNS privé d'Android est réglé sur un nom d'hôte, les requêtes contournent Bouclier. " +
                            "Laissez-le sur « Automatique » ou « Désactivé »."
                    },
                )
                HelpSection(
                    "Navigateur",
                    "Chrome, Brave ou Firefox peuvent utiliser leur propre « DNS sécurisé ». Désactivez-le dans " +
                        "les paramètres de confidentialité du navigateur.",
                )
                HelpSection(
                    "Publicités intégrées aux vidéos",
                    "YouTube, Instagram ou Facebook servent leurs publicités depuis les mêmes serveurs que leurs " +
                        "contenus : un bloqueur DNS ne peut pas les retirer sans casser l'application. Pour " +
                        "YouTube, préférez un navigateur avec bloqueur intégré (Firefox avec uBlock Origin, Brave…).",
                )
                HelpSection(
                    "Délai",
                    "Android garde les adresses en mémoire quelques minutes. Fermez puis rouvrez l'application " +
                        "concernée si une publicité reste affichée.",
                )
                HelpSection(
                    "Une application ne marche plus ?",
                    "Dans Statistiques, touchez le domaine bloqué dans le journal pour l'autoriser, ou excluez " +
                        "l'application dans l'onglet Applications.",
                )
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Compris") } },
        dismissButton = {
            TextButton(onClick = { SystemSettings.openNetworkSettings(context) }) { Text("Réglages réseau") }
        },
    )
}

@Composable
private fun HelpSection(title: String, body: String) {
    Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
    Spacer(Modifier.height(4.dp))
    Text(body, style = MaterialTheme.typography.bodyMedium)
    Spacer(Modifier.height(14.dp))
}
