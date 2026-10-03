package io.github.aaronjones56.bouclier.ui

import androidx.activity.ComponentActivity
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.PieChart
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import io.github.aaronjones56.bouclier.filter.FilterCatalog
import io.github.aaronjones56.bouclier.filter.FilterListState
import io.github.aaronjones56.bouclier.ui.theme.BouclierTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Écran d'accueil protection activée, rendu sans le service VPN. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w360dp-h800dp-xhdpi")
class HomeContentTest {

    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    private val lists = FilterCatalog.builtIn.map { info ->
        FilterListState(info, enabled = info.enabledByDefault, domainCount = 100_000, updatedAt = 1L, downloading = false, error = null)
    }

    private fun render(darkTheme: Boolean, onToggle: (Boolean) -> Unit = {}) {
        compose.setContent {
            BouclierTheme(darkTheme = darkTheme) {
                Scaffold(
                    containerColor = MaterialTheme.colorScheme.background,
                    bottomBar = { BottomBar(selected = Tab.HOME, onSelect = {}) },
                ) { padding ->
                    Box(Modifier.padding(padding)) {
                        HomeContent(
                            running = true,
                            starting = false,
                            lists = lists,
                            usingBuiltinList = false,
                            blockedDomainCount = 431_276,
                            updating = false,
                            todayBlocked = 127,
                            tips = listOf(
                                Tip("missed_ads", Icons.Outlined.Info, "Des publicités passent encore ? Voici comment y remédier.", warning = true) {},
                                Tip("stats", Icons.Outlined.PieChart, "Voyez ce qui a été bloqué aujourd'hui.") {},
                            ),
                            onToggle = onToggle,
                            onSync = {},
                            onOpenProtection = {},
                            onDismissTip = {},
                        )
                    }
                }
            }
        }
    }

    @Test
    fun showsActiveProtection() {
        val toggles = mutableListOf<Boolean>()
        render(darkTheme = true, onToggle = { toggles += it })

        compose.onNodeWithText("La protection est activée").assertIsDisplayed()
        compose.onNodeWithText("127 requêtes bloquées aujourd'hui", substring = true).assertIsDisplayed()
        compose.onNodeWithContentDescription("Interrupteur de protection").assertIsOn()
        compose.waitForIdle()
        compose.activity.window.decorView.saveScreenshot("0-accueil-active")

        compose.onNodeWithContentDescription("Interrupteur de protection").performClick()
        assertEquals(listOf(false), toggles)
    }

    @Test
    fun lightThemeRenders() {
        render(darkTheme = false)
        compose.onNodeWithText("La protection est activée").assertIsDisplayed()
        compose.waitForIdle()
        compose.activity.window.decorView.saveScreenshot("6-accueil-theme-clair")
    }
}
