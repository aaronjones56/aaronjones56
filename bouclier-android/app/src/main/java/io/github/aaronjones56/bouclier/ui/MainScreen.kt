package io.github.aaronjones56.bouclier.ui

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Category
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.PieChart
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Shield
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.aaronjones56.bouclier.ui.theme.BouclierTheme
import io.github.aaronjones56.bouclier.vpn.BouclierVpnService
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

/** Onglets de la barre de navigation. */
enum class Tab(val label: String, val icon: ImageVector) {
    HOME("Accueil", Icons.Outlined.Home),
    PROTECTION("Protection", Icons.Outlined.Shield),
    APPS("Applications", Icons.Outlined.Category),
    STATS("Statistiques", Icons.Outlined.PieChart),
    SETTINGS("Paramètres", Icons.Outlined.Settings),
}

/** Active ou désactive la protection, en demandant au besoin les autorisations. */
fun interface ProtectionController {
    fun setEnabled(enabled: Boolean)
}

@Composable
fun MainScreen(requestedTab: MutableStateFlow<Tab?>) {
    var tab by rememberSaveable { mutableStateOf(Tab.HOME) }
    val pendingTab by requestedTab.collectAsStateWithLifecycle()
    LaunchedEffect(pendingTab) {
        val target = pendingTab ?: return@LaunchedEffect
        tab = target
        requestedTab.value = null
    }
    BackHandler(enabled = tab != Tab.HOME) { tab = Tab.HOME }

    val snackbarHost = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    val showMessage: (String) -> Unit = remember {
        { message ->
            scope.launch {
                snackbarHost.currentSnackbarData?.dismiss()
                snackbarHost.showSnackbar(message)
            }
        }
    }
    val controller = rememberProtectionController(showMessage)

    val lastError by BouclierVpnService.lastError.collectAsStateWithLifecycle()
    LaunchedEffect(lastError) {
        val message = lastError ?: return@LaunchedEffect
        BouclierVpnService.clearError()
        showMessage(message)
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        snackbarHost = { SnackbarHost(snackbarHost) },
        bottomBar = { BottomBar(selected = tab, onSelect = { tab = it }) },
    ) { padding ->
        Box(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .consumeWindowInsets(padding),
        ) {
            when (tab) {
                Tab.HOME -> HomeScreen(controller = controller, onNavigate = { tab = it }, onMessage = showMessage)
                Tab.PROTECTION -> ProtectionScreen(onMessage = showMessage)
                Tab.APPS -> AppsScreen()
                Tab.STATS -> StatsScreen(onMessage = showMessage)
                Tab.SETTINGS -> SettingsScreen(onMessage = showMessage)
            }
        }
    }
}

@Composable
internal fun BottomBar(selected: Tab, onSelect: (Tab) -> Unit) {
    val accent = BouclierTheme.colors.accent
    Column(Modifier.background(MaterialTheme.colorScheme.background)) {
        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
        Row(
            Modifier
                .fillMaxWidth()
                .navigationBarsPadding()
                .height(64.dp),
        ) {
            Tab.entries.forEach { tab ->
                val isSelected = tab == selected
                Box(
                    Modifier
                        .weight(1f)
                        .fillMaxHeight()
                        .selectable(selected = isSelected, role = Role.Tab, onClick = { onSelect(tab) }),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        tab.icon,
                        contentDescription = tab.label,
                        tint = if (isSelected) accent else MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(28.dp),
                    )
                    if (isSelected) {
                        Box(
                            Modifier
                                .align(Alignment.BottomCenter)
                                .size(width = 52.dp, height = 4.dp)
                                .clip(RoundedCornerShape(topStart = 2.dp, topEnd = 2.dp))
                                .background(accent),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun rememberProtectionController(onMessage: (String) -> Unit): ProtectionController {
    val context = LocalContext.current
    val currentOnMessage by rememberUpdatedState(onMessage)
    val vpnPermission = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        if (result.resultCode == Activity.RESULT_OK) {
            BouclierVpnService.start(context)
        } else {
            currentOnMessage("Bouclier a besoin de l'autorisation VPN pour filtrer les publicités.")
        }
    }
    val startWithVpnPermission: () -> Unit = {
        val request = VpnService.prepare(context)
        if (request == null) {
            BouclierVpnService.start(context)
        } else {
            try {
                vpnPermission.launch(request)
            } catch (e: ActivityNotFoundException) {
                currentOnMessage("Ce téléphone ne permet pas de créer un VPN local.")
            }
        }
    }
    // La notification affiche les compteurs : on la demande avant d'activer la protection.
    val notificationPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        startWithVpnPermission()
    }
    return ProtectionController { enabled ->
        when {
            !enabled -> BouclierVpnService.stop(context)
            Build.VERSION.SDK_INT >= 33 &&
                ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
                PackageManager.PERMISSION_GRANTED -> notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
            else -> startWithVpnPermission()
        }
    }
}
