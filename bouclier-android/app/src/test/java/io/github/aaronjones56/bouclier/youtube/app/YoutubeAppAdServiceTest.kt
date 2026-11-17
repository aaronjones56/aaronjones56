package io.github.aaronjones56.bouclier.youtube.app

import android.content.Context
import android.graphics.Rect
import android.media.AudioManager
import android.os.Looper
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadow.api.Shadow
import org.robolectric.shadows.ShadowWindowManagerImpl
import java.time.Duration

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class YoutubeAppAdServiceTest {

    private val context: Context = ApplicationProvider.getApplicationContext()
    private val audio = context.getSystemService(AudioManager::class.java)

    private fun node(id: String? = null, text: String? = null, clickable: Boolean = false, bounds: Rect = Rect(0, 0, 1080, 2400)) =
        AccessibilityNodeInfo.obtain().apply {
            packageName = YoutubeAppAds.YOUTUBE_PACKAGE
            id?.let { viewIdResourceName = "${YoutubeAppAds.YOUTUBE_PACKAGE}:id/$it" }
            this.text = text
            isClickable = clickable
            isEnabled = true
            isVisibleToUser = true
            setBoundsInScreen(bounds)
        }

    private fun AccessibilityNodeInfo.with(vararg children: AccessibilityNodeInfo) = apply {
        children.forEach { shadowOf(this).addChild(it) }
    }

    private fun window(root: AccessibilityNodeInfo) = AccessibilityWindowInfo.obtain().also { shadowOf(it).setRoot(root) }

    private fun event() = AccessibilityEvent.obtain(AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED).apply {
        packageName = YoutubeAppAds.YOUTUBE_PACKAGE
    }

    private fun overlays(windowManager: WindowManager) = Shadow.extract<ShadowWindowManagerImpl>(windowManager).views.size

    private fun idle(millis: Long) = shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(millis))

    @Test
    fun adIsMutedCoveredSkippedThenTheVideoComesBack() {
        val service = Robolectric.setupService(YoutubeAppAdService::class.java)
        YoutubeAppAdService::class.java.getDeclaredMethod("onServiceConnected").apply { isAccessible = true }.invoke(service)
        val windowManager = service.getSystemService(WindowManager::class.java)
        val before = YoutubeAppAds.stats.value
        audio.setStreamVolume(AudioManager.STREAM_MUSIC, 8, 0)

        // Pub en cours : compte à rebours, puis bouton « Ignorer ».
        val skip = node(id = "skip_ad_button", text = "Ignorer", clickable = true, bounds = Rect(800, 600, 1060, 700))
        val player = node(id = "watch_player", bounds = Rect(0, 150, 1080, 760))
            .with(node(text = "Sponsorisé · 0:12", bounds = Rect(20, 680, 400, 740)), skip)
        shadowOf(service).setWindows(listOf(window(node().with(player))))
        service.onAccessibilityEvent(event())
        idle(300)

        assertTrue("son coupé", audio.isStreamMute(AudioManager.STREAM_MUSIC))
        assertEquals("pub masquée", 1, overlays(windowManager))
        assertTrue("« Ignorer » touché", shadowOf(skip).performedActions.contains(AccessibilityNodeInfo.ACTION_CLICK))
        assertEquals(YoutubeAppStats(before.adsHidden + 1, before.adsSkipped + 1), YoutubeAppAds.stats.value)

        // La vidéo reprend : plus aucun élément de pub.
        val video = node(id = "watch_player", bounds = Rect(0, 150, 1080, 760)).with(node(text = "0:03 / 3:45"))
        shadowOf(service).setWindows(listOf(window(node().with(video))))
        idle(1500)

        assertFalse("son rétabli", audio.isStreamMute(AudioManager.STREAM_MUSIC))
        assertEquals("masque retiré", 0, overlays(windowManager))
        assertEquals(before.adsHidden + 1, YoutubeAppAds.stats.value.adsHidden)
    }

    @Test
    fun buttonWithoutClickActionIsTappedLikeAFinger() {
        val service = Robolectric.setupService(YoutubeAppAdService::class.java)
        YoutubeAppAdService::class.java.getDeclaredMethod("onServiceConnected").apply { isAccessible = true }.invoke(service)
        shadowOf(service).setCanDispatchGestures(true)
        val skip = node(id = "modern_skip_ad_text", text = "Ignorer", bounds = Rect(800, 600, 1060, 700))
        shadowOf(service).setWindows(listOf(window(node().with(node(id = "watch_player", bounds = Rect(0, 150, 1080, 760)).with(skip)))))
        service.onAccessibilityEvent(event())
        idle(300)
        assertEquals(1, shadowOf(service).gesturesDispatched.size)
    }

    @Test
    fun soundAlreadyOffStaysOff() {
        val service = Robolectric.setupService(YoutubeAppAdService::class.java)
        YoutubeAppAdService::class.java.getDeclaredMethod("onServiceConnected").apply { isAccessible = true }.invoke(service)
        audio.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_MUTE, 0)

        shadowOf(service).setWindows(listOf(window(node().with(node(id = "ad_progress_text", text = "0:09")))))
        service.onAccessibilityEvent(event())
        idle(300)
        shadowOf(service).setWindows(emptyList())
        idle(1500)

        assertTrue("l'utilisateur avait coupé le son lui-même", audio.isStreamMute(AudioManager.STREAM_MUSIC))
    }

    @Test
    fun otherAppsAreIgnored() {
        val service = Robolectric.setupService(YoutubeAppAdService::class.java)
        YoutubeAppAdService::class.java.getDeclaredMethod("onServiceConnected").apply { isAccessible = true }.invoke(service)
        val ad = node(id = "ad_progress_text", text = "0:09").apply { packageName = "com.example.other" }
        shadowOf(service).setWindows(listOf(window(ad)))
        service.onAccessibilityEvent(event())
        idle(300)
        assertFalse(audio.isStreamMute(AudioManager.STREAM_MUSIC))
        assertEquals(0, overlays(service.getSystemService(WindowManager::class.java)))
    }
}
