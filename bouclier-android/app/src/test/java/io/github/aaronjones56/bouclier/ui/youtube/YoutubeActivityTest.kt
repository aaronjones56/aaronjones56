package io.github.aaronjones56.bouclier.ui.youtube

import android.content.Intent
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class YoutubeActivityTest {

    private fun intent(action: String) =
        Intent(ApplicationProvider.getApplicationContext(), YoutubeActivity::class.java).setAction(action)

    @Test
    fun sharedVideoOpensWithoutAds() {
        val share = intent(Intent.ACTION_SEND)
            .setType("text/plain")
            .putExtra(Intent.EXTRA_TEXT, "Regarde ça https://youtu.be/dQw4w9WgXcQ?si=AbCdEf")
        val activity = Robolectric.buildActivity(YoutubeActivity::class.java, share).setup().get()

        assertEquals("https://m.youtube.com/watch?v=dQw4w9WgXcQ", shadowOf(activity.webView).lastLoadedUrl)
        assertTrue(activity.webView.settings.javaScriptEnabled)
        assertFalse(activity.webView.settings.userAgentString.contains("; wv)"))
        assertFalse(activity.isFinishing)
    }

    @Test
    fun youtubeLinkOpensOnTheMobileSite() {
        val view = intent(Intent.ACTION_VIEW).setData(Uri.parse("https://www.youtube.com/shorts/aBcDeFgHiJk"))
        val activity = Robolectric.buildActivity(YoutubeActivity::class.java, view).setup().get()
        assertEquals("https://m.youtube.com/shorts/aBcDeFgHiJk", shadowOf(activity.webView).lastLoadedUrl)
    }

    @Test
    fun openingFromTheAppShowsYoutubeHome() {
        val activity = Robolectric.buildActivity(YoutubeActivity::class.java).setup().get()
        assertEquals("https://m.youtube.com/", shadowOf(activity.webView).lastLoadedUrl)
    }

    @Test
    fun shareWithoutYoutubeLinkCloses() {
        val share = intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, "Bonjour")
        val activity = Robolectric.buildActivity(YoutubeActivity::class.java, share).setup().get()
        assertTrue(activity.isFinishing)
        assertNull(shadowOf(activity.webView).lastLoadedUrl)
    }

    @Test
    fun anotherShareReplacesTheVideo() {
        val controller = Robolectric.buildActivity(YoutubeActivity::class.java).setup()
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
