package io.github.aaronjones56.bouclier.ui.youtube

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import io.github.aaronjones56.bouclier.youtube.YoutubeRulesRepository
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class YoutubeActivityTest {

    private fun intent(action: String) =
        Intent(ApplicationProvider.getApplicationContext(), YoutubeActivity::class.java).setAction(action)

    @Before
    fun waitForRules() {
        // Pas de téléchargement des listes pendant les tests : règles fournies avec l'application.
        val now = System.currentTimeMillis()
        ApplicationProvider.getApplicationContext<Context>().getSharedPreferences("youtube_rules", Context.MODE_PRIVATE)
            .edit().putLong("updated_adguard", now).putLong("updated_ubo", now).commit()
        // Les règles se chargent au démarrage de l'application, en arrière-plan.
        runBlocking { withTimeout(30_000) { YoutubeRulesRepository.playerRules.filterNotNull().first() } }
    }

    /** Laisse l'activité installer les règles, puis charger la page. */
    private fun settle() = shadowOf(Looper.getMainLooper()).idle()

    @Test
    fun rulesAreInstalledBeforeThePageLoads() {
        val rules = YoutubeRulesRepository.playerRules.value!!
        // Script intégré, scriptlets des listes, JavaScript d'AdGuard, masquage CSS.
        assertEquals(4, rules.scripts.size)
        assertTrue(rules.scripts[0].contains("__bouclierYoutube"))
        assertTrue(rules.scripts[1].contains("function setConstant"))
        assertTrue(rules.scripts[1].contains("function jsonPruneFetchResponse"))
        assertTrue(rules.blockedUrls.any { it.containsMatchIn("https://www.youtube.com/pagead/1") })

        // Copie pour le banc d'essai dans Chromium (tools/test-youtube-adblock.cjs).
        val directory = File("build/youtube-scripts").apply { deleteRecursively(); mkdirs() }
        rules.scripts.forEachIndexed { index, script -> File(directory, "%02d.js".format(index)).writeText(script) }
    }

    @Test
    fun sharedVideoOpensWithoutAds() {
        val share = intent(Intent.ACTION_SEND)
            .setType("text/plain")
            .putExtra(Intent.EXTRA_TEXT, "Regarde ça https://youtu.be/dQw4w9WgXcQ?si=AbCdEf")
        val activity = Robolectric.buildActivity(YoutubeActivity::class.java, share).setup().get()
        settle()

        assertEquals("https://m.youtube.com/watch?v=dQw4w9WgXcQ", shadowOf(activity.webView).lastLoadedUrl)
        assertTrue(activity.webView.settings.javaScriptEnabled)
        assertFalse(activity.webView.settings.userAgentString.contains("; wv)"))
        assertFalse(activity.isFinishing)
    }

    @Test
    fun youtubeLinkOpensOnTheMobileSite() {
        val view = intent(Intent.ACTION_VIEW).setData(Uri.parse("https://www.youtube.com/shorts/aBcDeFgHiJk"))
        val activity = Robolectric.buildActivity(YoutubeActivity::class.java, view).setup().get()
        settle()
        assertEquals("https://m.youtube.com/shorts/aBcDeFgHiJk", shadowOf(activity.webView).lastLoadedUrl)
    }

    @Test
    fun openingFromTheAppShowsYoutubeHome() {
        val activity = Robolectric.buildActivity(YoutubeActivity::class.java).setup().get()
        settle()
        assertEquals("https://m.youtube.com/", shadowOf(activity.webView).lastLoadedUrl)
    }

    @Test
    fun shareWithoutYoutubeLinkCloses() {
        val share = intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, "Bonjour")
        val activity = Robolectric.buildActivity(YoutubeActivity::class.java, share).setup().get()
        settle()
        assertTrue(activity.isFinishing)
        assertNull(shadowOf(activity.webView).lastLoadedUrl)
    }

    @Test
    fun anotherShareReplacesTheVideo() {
        val controller = Robolectric.buildActivity(YoutubeActivity::class.java).setup()
        settle()
        controller.newIntent(
            intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, "https://youtu.be/aBcDeFgHiJk?t=42"),
        )
        assertEquals("https://m.youtube.com/watch?v=aBcDeFgHiJk&t=42", shadowOf(controller.get().webView).lastLoadedUrl)
    }

    @Test
    fun userAgentLooksLikeChrome() {
        val webView = "Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/AP1A; wv) AppleWebKit/537.36 (KHTML, like Gecko) " +
            "Version/4.0 Chrome/139.0.7258.94 Mobile Safari/537.36"
        assertEquals(
            "Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/AP1A) AppleWebKit/537.36 (KHTML, like Gecko) " +
                "Chrome/139.0.7258.94 Mobile Safari/537.36",
            YoutubeActivity.browserUserAgent(webView),
        )
    }
}
