package io.github.aaronjones56.bouclier.ui

import android.content.Intent
import android.content.res.Configuration
import android.graphics.Color
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.aaronjones56.bouclier.data.SettingsRepository
import io.github.aaronjones56.bouclier.data.ThemeMode
import io.github.aaronjones56.bouclier.ui.theme.BouclierTheme
import kotlinx.coroutines.flow.MutableStateFlow

class MainActivity : ComponentActivity() {

    /** Onglet demandé par une notification, consommé par l'interface. */
    private val requestedTab = MutableStateFlow<Tab?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        applySystemBars(isDark(SettingsRepository.state.value.theme, systemDark()))
        readTab(intent)
        setContent {
            val settings by SettingsRepository.state.collectAsStateWithLifecycle()
            val dark = isDark(settings.theme, isSystemInDarkTheme())
            LaunchedEffect(dark) { applySystemBars(dark) }
            BouclierTheme(darkTheme = dark) {
                MainScreen(requestedTab)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        readTab(intent)
    }

    private fun readTab(intent: Intent?) {
        val name = intent?.getStringExtra(EXTRA_TAB) ?: return
        requestedTab.value = Tab.entries.firstOrNull { it.name == name }
    }

    private fun systemDark(): Boolean =
        resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES

    private fun isDark(theme: ThemeMode, systemDark: Boolean) = when (theme) {
        ThemeMode.DARK -> true
        ThemeMode.LIGHT -> false
        ThemeMode.SYSTEM -> systemDark
    }

    private fun applySystemBars(dark: Boolean) {
        val style = if (dark) {
            SystemBarStyle.dark(Color.TRANSPARENT)
        } else {
            SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT)
        }
        enableEdgeToEdge(statusBarStyle = style, navigationBarStyle = style)
    }

    companion object {
        const val EXTRA_TAB = "tab"
        const val TAB_STATS = "STATS"
    }
}
