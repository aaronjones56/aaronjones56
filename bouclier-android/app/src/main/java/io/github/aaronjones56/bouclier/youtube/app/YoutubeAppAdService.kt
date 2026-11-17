package io.github.aaronjones56.bouclier.youtube.app

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Color
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.Rect
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView

/**
 * Bloque les pubs dans l'application YouTube officielle, sans root.
 *
 * Les pubs de l'appli arrivent chiffrées, des mêmes serveurs que les vidéos : aucune application
 * ne peut les retirer du flux sans root. Ce service agit donc à l'écran, dès que la pub apparaît :
 * il coupe le son, la recouvre d'un écran noir, et touche « Ignorer » dès que YouTube le permet.
 * Il ne reçoit que les événements de l'appli YouTube (voir res/xml/youtube_app_ads.xml) et ne lit
 * que les éléments visibles du lecteur ; rien n'est enregistré ni envoyé.
 */
class YoutubeAppAdService : AccessibilityService() {

    private val handler = Handler(Looper.getMainLooper())
    private lateinit var audio: AudioManager
    private lateinit var windowManager: WindowManager

    private var scanPosted = false
    private var lastScanAt = 0L
    private var adActive = false
    private var adStartedAt = 0L
    private var lastAdSeenAt = 0L
    private var lastSkipAt = Long.MIN_VALUE / 2
    private var skippedThisAd = false
    private var mutedByUs = false
    private var overlay: View? = null
    private var overlayArea: Box? = null
    private var coverGivenUp = false

    private val scanRunnable = Runnable {
        scanPosted = false
        scan()
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        audio = getSystemService(AudioManager::class.java)
        windowManager = getSystemService(WindowManager::class.java)
        YoutubeAppAds.setRunning(true)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val packageName = event?.packageName?.toString() ?: return
        if (packageName in YoutubeAppAds.TARGET_PACKAGES) requestScan()
    }

    override fun onInterrupt() = Unit

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        endAd()
        YoutubeAppAds.setRunning(false)
        super.onDestroy()
    }

    /** Analyse de l'écran au plus tôt, sans dépasser une analyse toutes les [MIN_SCAN_INTERVAL_MS]. */
    private fun requestScan(delay: Long = 0) {
        if (scanPosted) return
        scanPosted = true
        val wait = maxOf(delay, lastScanAt + MIN_SCAN_INTERVAL_MS - SystemClock.uptimeMillis(), 0L)
        handler.postDelayed(scanRunnable, wait)
    }

    private fun scan() {
        val now = SystemClock.uptimeMillis()
        lastScanAt = now
        val result = try {
            AppAdDetector.scan(youtubeRoots().map { NodeAdapter(it, null) })
        } catch (e: RuntimeException) {
            // Écran modifié pendant la lecture : on réessaie à l'analyse suivante.
            Log.w(TAG, "Analyse de l'écran impossible", e)
            null
        }
        if (result != null) {
            YoutubeAppAds.recordScan(result)
            if (result.adShowing) {
                lastAdSeenAt = now
                onAd(result, now)
            }
        }
        if (adActive && now - lastAdSeenAt > AD_END_DELAY_MS) endAd()
        // Pendant une pub, on regarde sans attendre d'événement : le bouton « Ignorer » peut apparaître à tout moment.
        if (adActive) requestScan(POLL_DURING_AD_MS)
    }

    /** Fenêtres de YouTube à l'écran (plein écran, lecteur réduit…). */
    private fun youtubeRoots(): List<AccessibilityNodeInfo> {
        val roots = windows.mapNotNull { it.root }.filter { it.packageName?.toString() in YoutubeAppAds.TARGET_PACKAGES }
        if (roots.isNotEmpty()) return roots
        return listOfNotNull(rootInActiveWindow?.takeIf { it.packageName?.toString() in YoutubeAppAds.TARGET_PACKAGES })
    }

    private fun onAd(result: AdScan, now: Long) {
        if (!adActive) {
            adActive = true
            adStartedAt = now
            skippedThisAd = false
            coverGivenUp = false
            mute()
            YoutubeAppAds.recordAdHidden()
            Log.i(TAG, "Pub détectée : ${result.signals}")
        }
        // Sécurité : si « la pub » dure anormalement, on rend l'écran et le son (fausse détection ?).
        if (!coverGivenUp && now - adStartedAt > MAX_COVER_MS) {
            coverGivenUp = true
            hideOverlay()
            unmute()
        }
        if (!coverGivenUp) showOverlay(result.playerArea)
        if ((result.skipTarget != null || result.skipBounds != null) && now - lastSkipAt > SKIP_RETRY_MS) {
            lastSkipAt = now
            skip(result)
        }
    }

    private fun endAd() {
        if (!adActive) return
        adActive = false
        hideOverlay()
        unmute()
    }

    // --- « Ignorer » ---

    private fun skip(result: AdScan) {
        val clicked = (result.skipTarget as? NodeAdapter)?.info?.performAction(AccessibilityNodeInfo.ACTION_CLICK) == true
        if (clicked) {
            countSkip()
            return
        }
        // Bouton dessiné sans action d'accessibilité : on le touche comme un doigt.
        val bounds = result.skipBounds ?: return
        val path = Path().apply { moveTo(bounds.centerX.toFloat(), bounds.centerY.toFloat()) }
        val gesture = GestureDescription.Builder().addStroke(GestureDescription.StrokeDescription(path, 0, TAP_DURATION_MS)).build()
        dispatchGesture(gesture, object : GestureResultCallback() {
            override fun onCompleted(gestureDescription: GestureDescription?) = countSkip()
        }, handler)
    }

    private fun countSkip() {
        if (skippedThisAd) return
        skippedThisAd = true
        YoutubeAppAds.recordAdSkipped()
    }

    // --- Son ---

    private fun mute() {
        try {
            if (!audio.isStreamMute(AudioManager.STREAM_MUSIC)) {
                audio.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_MUTE, 0)
                mutedByUs = true
            }
        } catch (e: SecurityException) {
            Log.w(TAG, "Impossible de couper le son", e)
        }
    }

    private fun unmute() {
        if (!mutedByUs) return
        mutedByUs = false
        try {
            audio.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_UNMUTE, 0)
        } catch (e: SecurityException) {
            Log.w(TAG, "Impossible de rétablir le son", e)
        }
    }

    // --- Écran noir sur la pub ---

    private fun showOverlay(area: Box?) {
        val params = overlayParams(area)
        val view = overlay
        try {
            if (view == null) {
                val created = overlayView()
                windowManager.addView(created, params)
                overlay = created
            } else if (area != overlayArea) {
                windowManager.updateViewLayout(view, params)
            }
            overlayArea = area
        } catch (e: RuntimeException) {
            Log.w(TAG, "Impossible de masquer la pub", e)
        }
    }

    private fun hideOverlay() {
        val view = overlay ?: return
        overlay = null
        overlayArea = null
        try {
            windowManager.removeView(view)
        } catch (e: RuntimeException) {
            Log.w(TAG, "Masque déjà retiré", e)
        }
    }

    private fun overlayParams(area: Box?): WindowManager.LayoutParams {
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            // Les touchers traversent le masque : le bouton « Ignorer » et le lecteur restent utilisables.
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        )
        params.gravity = Gravity.TOP or Gravity.START
        if (Build.VERSION.SDK_INT >= 28) {
            params.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
        if (area != null && !area.isEmpty) {
            params.x = area.left
            params.y = area.top
            params.width = area.right - area.left
            params.height = area.bottom - area.top
        } else {
            params.width = WindowManager.LayoutParams.MATCH_PARENT
            params.height = WindowManager.LayoutParams.MATCH_PARENT
        }
        return params
    }

    private fun overlayView(): View {
        fun text(value: String, size: Float, alpha: Float) = TextView(this).apply {
            text = value
            setTextColor(Color.WHITE)
            this.alpha = alpha
            gravity = Gravity.CENTER
            setTextSize(TypedValue.COMPLEX_UNIT_SP, size)
        }
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            addView(text("🛡  Pub masquée par Bouclier", 16f, 1f))
            addView(text("Son coupé · la vidéo reprend dès que possible", 12f, 0.7f))
        }
        return FrameLayout(this).apply {
            setBackgroundColor(Color.argb(250, 8, 8, 8))
            addView(column, FrameLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.CENTER))
        }
    }

    /** Élément d'écran Android vu à travers l'interface du détecteur. */
    private class NodeAdapter(val info: AccessibilityNodeInfo, private val parentNode: NodeAdapter?) : ScreenNode {
        override val viewId: String? get() = info.viewIdResourceName
        override val text: String? get() = info.text?.toString()
        override val description: String? get() = info.contentDescription?.toString()
        override val isClickable: Boolean get() = info.isClickable
        override val isEnabled: Boolean get() = info.isEnabled
        override val isVisible: Boolean get() = info.isVisibleToUser
        override val bounds: Box by lazy {
            val rect = Rect()
            info.getBoundsInScreen(rect)
            Box(rect.left, rect.top, rect.right, rect.bottom)
        }
        override val parent: ScreenNode? get() = parentNode
        override val childCount: Int get() = info.childCount
        override fun child(index: Int): ScreenNode? = info.getChild(index)?.let { NodeAdapter(it, this) }
    }

    private companion object {
        const val TAG = "YoutubeAppAds"
        const val MIN_SCAN_INTERVAL_MS = 200L
        const val POLL_DURING_AD_MS = 250L
        const val AD_END_DELAY_MS = 900L
        const val SKIP_RETRY_MS = 600L
        const val TAP_DURATION_MS = 60L

        /** Au-delà, le masque est retiré : aucune pub ne dure aussi longtemps sans bouton « Ignorer ». */
        const val MAX_COVER_MS = 150_000L
    }
}
