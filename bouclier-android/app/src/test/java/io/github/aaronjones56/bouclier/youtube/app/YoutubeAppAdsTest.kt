package io.github.aaronjones56.bouclier.youtube.app

import android.content.ComponentName
import android.content.Context
import android.provider.Settings
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class YoutubeAppAdsTest {

    private val context: Context = ApplicationProvider.getApplicationContext()

    @Test
    fun detectsWhenTheServiceIsEnabledInAccessibilitySettings() {
        assertFalse(YoutubeAppAds.isEnabled(context))
        val ours = ComponentName(context, YoutubeAppAdService::class.java).flattenToString()
        Settings.Secure.putString(
            context.contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
            "com.example.reader/.ReaderService:$ours",
        )
        assertTrue(YoutubeAppAds.isEnabled(context))
    }

    @Test
    fun countsAreKept() {
        val before = YoutubeAppAds.stats.value
        YoutubeAppAds.recordAdHidden()
        YoutubeAppAds.recordAdSkipped()
        assertEquals(YoutubeAppStats(before.adsHidden + 1, before.adsSkipped + 1), YoutubeAppAds.stats.value)
        YoutubeAppAds.init(context)
        assertEquals(YoutubeAppStats(before.adsHidden + 1, before.adsSkipped + 1), YoutubeAppAds.stats.value)
    }

    @Test
    fun reportListsWhatTheServiceSaw() {
        val ad = AdScan(
            adShowing = true,
            skipTarget = null,
            skipBounds = null,
            playerArea = null,
            signals = listOf("id:ad_progress_text"),
            clues = setOf("id:ad_progress_text", "texte:Sponsorisé · 0:15"),
        )
        YoutubeAppAds.recordScan(ad)
        YoutubeAppAds.recordScan(ad) // même écran : noté une seule fois
        val report = YoutubeAppAds.report(context)
        assertTrue(report, report.contains("PUB (id:ad_progress_text)"))
        assertEquals(1, Regex("Sponsorisé · 0:15").findAll(report).count())
        assertTrue(report.contains("YouTube non installé"))
    }
}
