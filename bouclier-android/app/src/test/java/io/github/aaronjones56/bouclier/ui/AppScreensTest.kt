package io.github.aaronjones56.bouclier.ui

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextInput
import io.github.aaronjones56.bouclier.data.DnsProvider
import io.github.aaronjones56.bouclier.data.SettingsRepository
import io.github.aaronjones56.bouclier.filter.FilterRepository
import io.github.aaronjones56.bouclier.filter.Verdict
import io.github.aaronjones56.bouclier.net.DnsMessages
import io.github.aaronjones56.bouclier.stats.StatsRepository
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Parcourt l'application réelle (Robolectric) : chaque onglet s'affiche et ses actions principales marchent. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w360dp-h800dp-xhdpi")
class AppScreensTest {

    @get:Rule
    val compose = createAndroidComposeRule<MainActivity>()

    private fun screenshot(name: String) {
        compose.waitForIdle()
        compose.activity.window.decorView.saveScreenshot(name)
    }

    @Test
    fun homeScreenShowsProtectionOff() {
        compose.onNodeWithText("La protection est désactivée").assertIsDisplayed()
        compose.onNodeWithContentDescription("Interrupteur de protection").assertIsDisplayed()
        compose.onNodeWithText("Des publicités passent encore ? Voici comment y remédier.").assertIsDisplayed()
        screenshot("1-accueil-desactive")
    }

    @Test
    fun missedAdsHelpOpens() {
        compose.onNodeWithText("Des publicités passent encore ? Voici comment y remédier.").performClick()
        compose.onNodeWithText("Publicités non bloquées").assertIsDisplayed()
        compose.onNodeWithText("Compris").performClick()
        compose.onNodeWithText("La protection est désactivée").assertIsDisplayed()
    }

    @Test
    fun protectionTabListsFiltersAndAcceptsUserRules() {
        compose.onNodeWithContentDescription("Protection").performClick()
        compose.onNodeWithText("AdGuard DNS filter").assertIsDisplayed()
        screenshot("2-protection")

        compose.onNode(hasScrollAction()).performScrollToNode(hasText("Domaines bloqués (0)"))
        compose.onNodeWithText("Domaines bloqués (0)").performClick()
        compose.onNode(hasSetTextAction()).performTextInput("https://pub.exemple.com/banniere")
        compose.onNodeWithContentDescription("Ajouter").performClick()
        compose.waitForIdle()

        assertTrue("pub.exemple.com" in FilterRepository.userRules.value.blocked)
        assertEquals(Verdict.BLOCKED_BY_USER, FilterRepository.matcher.value.verdict("cdn.pub.exemple.com"))
        compose.onNodeWithText("Domaines bloqués (1)").assertIsDisplayed()
        FilterRepository.removeUserRule("pub.exemple.com")
    }

    @Test
    fun appsTabRenders() {
        compose.onNodeWithContentDescription("Applications").performClick()
        compose.onNodeWithText("Rechercher une application").assertIsDisplayed()
        screenshot("3-applications")
    }

    @Test
    fun statsTabShowsQueriesAndAllowsADomain() {
        StatsRepository.reset()
        repeat(12) { StatsRepository.record("pagead2.googlesyndication.com", DnsMessages.TYPE_A, Verdict.BLOCKED) }
        repeat(5) { StatsRepository.record("app-measurement.com", DnsMessages.TYPE_AAAA, Verdict.BLOCKED) }
        repeat(30) { StatsRepository.record("www.wikipedia.org", DnsMessages.TYPE_A, Verdict.ALLOWED) }

        compose.onNodeWithContentDescription("Statistiques").performClick()
        compose.onNodeWithText("Statistiques").assertIsDisplayed()
        compose.onNodeWithText("47").assertIsDisplayed() // requêtes du jour
        screenshot("4-statistiques")

        compose.onAllNodesWithText("pagead2.googlesyndication.com").onFirst().performClick()
        compose.onNodeWithText("Toujours autoriser ce domaine").performClick()
        compose.waitForIdle()
        assertTrue("pagead2.googlesyndication.com" in FilterRepository.userRules.value.allowed)
        FilterRepository.removeUserRule("pagead2.googlesyndication.com")
    }

    @Test
    fun settingsTabChangesDnsServer() {
        compose.onNodeWithContentDescription("Paramètres").performClick()
        compose.onNodeWithText("Démarrer avec le téléphone").assertIsDisplayed()
        screenshot("5-parametres")

        compose.onNodeWithText("Serveur DNS").performClick()
        compose.onNodeWithText("Quad9").performClick()
        compose.onNodeWithText("Enregistrer").performClick()
        compose.waitForIdle()
        assertEquals(DnsProvider.QUAD9, SettingsRepository.state.value.dnsProvider)
        SettingsRepository.update { it.copy(dnsProvider = DnsProvider.AUTO) }
    }
}
