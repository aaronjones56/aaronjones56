package io.github.aaronjones56.bouclier.ui.youtube

import android.annotation.SuppressLint
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.res.ColorStateList
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.WindowManager
import android.webkit.CookieManager
import android.webkit.ServiceWorkerClient
import android.webkit.ServiceWorkerController
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.ProgressBar
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import io.github.aaronjones56.bouclier.R
import io.github.aaronjones56.bouclier.filter.FilterRepository
import io.github.aaronjones56.bouclier.youtube.YoutubeLinks
import io.github.aaronjones56.bouclier.youtube.YoutubeRequestFilter
import java.io.ByteArrayInputStream

/**
 * Lecteur YouTube sans publicité : le site mobile de YouTube, chargé dans une WebView où
 * un script retire les annonces avant qu'elles ne démarrent et où les requêtes
 * publicitaires sont bloquées. S'ouvre depuis l'accueil, depuis le bouton « Partager »
 * de l'application YouTube ou depuis un lien youtube.com.
 */
class YoutubeActivity : ComponentActivity() {

    internal lateinit var webView: WebView
        private set
    private lateinit var progress: ProgressBar
    private lateinit var fullscreenContainer: FrameLayout
    private var customView: View? = null
    private var customViewCallback: WebChromeClient.CustomViewCallback? = null
    private var scriptInjectedAtDocumentStart = false

    private val adblockScript: String by lazy {
        assets.open("youtube/adblock.js").bufferedReader().use { it.readText() }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
        )
        buildViews()
        configureWebView()
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                when {
                    customView != null -> exitFullscreen(notifyPage = true)
                    webView.canGoBack() -> webView.goBack()
                    else -> finish()
                }
            }
        })
        if (savedInstanceState == null || webView.restoreState(savedInstanceState) == null) {
            open(intent)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        open(intent)
    }

    override fun onResume() {
        super.onResume()
        webView.onResume()
    }

    override fun onPause() {
        webView.onPause()
        super.onPause()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        webView.saveState(outState)
    }

    override fun onDestroy() {
        (webView.parent as? FrameLayout)?.removeView(webView)
        webView.destroy()
        super.onDestroy()
    }

    private fun open(intent: Intent?) {
        val url = targetUrl(intent)
        if (url != null) {
            webView.loadUrl(url)
            return
        }
        Toast.makeText(this, "Aucun lien YouTube dans ce partage.", Toast.LENGTH_LONG).show()
        if (webView.url == null) finish()
    }

    private fun buildViews() {
        val content = FrameLayout(this).apply { setBackgroundColor(BACKGROUND) }
        webView = WebView(this).apply { setBackgroundColor(BACKGROUND) }
        progress = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 100
            progressTintList = ColorStateList.valueOf(ContextCompat.getColor(context, R.color.brand_green))
        }
        content.addView(webView, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        content.addView(progress, FrameLayout.LayoutParams(MATCH_PARENT, (3 * resources.displayMetrics.density).toInt(), Gravity.TOP))
        fullscreenContainer = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            visibility = View.GONE
        }
        val root = FrameLayout(this).apply { setBackgroundColor(BACKGROUND) }
        root.addView(content, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        root.addView(fullscreenContainer, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        setContentView(root)
        // Affichage bord à bord : la page ne doit pas passer sous les barres du système.
        ViewCompat.setOnApplyWindowInsetsListener(content) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            WindowInsetsCompat.CONSUMED
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun configureWebView() {
        CookieManager.getInstance().apply {
            setAcceptCookie(true)
            // Choix « Tout refuser » de YouTube : pas d'écran de consentement, pas de cookies publicitaires.
            if (getCookie(YOUTUBE_ORIGIN)?.contains("SOCS=") != true) {
                setCookie(YOUTUBE_ORIGIN, "SOCS=CAI; Domain=.youtube.com; Path=/; Secure")
            }
        }
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            mediaPlaybackRequiresUserGesture = false
            setSupportMultipleWindows(false)
            // YouTube sert sa version mobile complète aux navigateurs, pas aux WebView.
            userAgentString = browserUserAgent(userAgentString)
        }
        scriptInjectedAtDocumentStart = try {
            if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
                WebViewCompat.addDocumentStartJavaScript(webView, adblockScript, setOf("https://*.youtube.com", "https://youtube.com"))
                true
            } else {
                false
            }
        } catch (e: Exception) {
            Log.w(TAG, "Injection au démarrage des pages impossible", e)
            false
        }
        webView.webViewClient = PlayerWebViewClient()
        webView.webChromeClient = PlayerChromeClient()
        try {
            ServiceWorkerController.getInstance().setServiceWorkerClient(object : ServiceWorkerClient() {
                override fun shouldInterceptRequest(request: WebResourceRequest): WebResourceResponse? =
                    blockedResponse(request.url.toString())
            })
        } catch (e: Exception) {
            Log.w(TAG, "Filtrage des service workers indisponible", e)
        }
    }

    /** Réponse vide pour une requête publicitaire, `null` pour laisser passer la requête. */
    private fun blockedResponse(url: String): WebResourceResponse? {
        if (!YoutubeRequestFilter.shouldBlock(url, FilterRepository.matcher.value)) return null
        return WebResourceResponse("text/plain", "utf-8", 204, "No Content", emptyMap(), ByteArrayInputStream(ByteArray(0)))
    }

    private inner class PlayerWebViewClient : WebViewClient() {
        override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? =
            blockedResponse(request.url.toString())

        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
            if (!request.isForMainFrame) return false
            val url = request.url
            val scheme = url.scheme?.lowercase()
            if (scheme != "http" && scheme != "https") {
                // « intent:// », « vnd.youtube: »… renverraient vers l'appli YouTube et ses publicités.
                return true
            }
            val host = url.host?.lowercase().orEmpty()
            if (YoutubeLinks.isYoutubeHost(host)) {
                // Liens youtu.be ou www.youtube.com : on reste sur le site mobile.
                if (host != MOBILE_HOST) {
                    YoutubeLinks.toMobileUrl(url.toString())?.let { mobile ->
                        view.loadUrl(mobile)
                        return true
                    }
                }
                return false
            }
            if (host == "google.com" || host.endsWith(".google.com") || host.endsWith(".youtube.com")) return false
            openExternally(url)
            return true
        }

        override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
            // WebView trop ancienne pour l'injection au démarrage : on injecte au plus tôt.
            if (!scriptInjectedAtDocumentStart) view.evaluateJavascript(adblockScript, null)
        }
    }

    private inner class PlayerChromeClient : WebChromeClient() {
        override fun onProgressChanged(view: WebView, newProgress: Int) {
            progress.progress = newProgress
            progress.visibility = if (newProgress >= 100) View.GONE else View.VISIBLE
        }

        override fun onShowCustomView(view: View, callback: CustomViewCallback) {
            if (customView != null) {
                callback.onCustomViewHidden()
                return
            }
            customView = view
            customViewCallback = callback
            fullscreenContainer.addView(view, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
            fullscreenContainer.visibility = View.VISIBLE
            setFullscreen(true)
        }

        override fun onHideCustomView() {
            exitFullscreen(notifyPage = false)
        }
    }

    private fun exitFullscreen(notifyPage: Boolean) {
        val view = customView ?: return
        customView = null
        fullscreenContainer.removeView(view)
        fullscreenContainer.visibility = View.GONE
        setFullscreen(false)
        val callback = customViewCallback
        customViewCallback = null
        if (notifyPage) callback?.onCustomViewHidden()
    }

    private fun setFullscreen(enabled: Boolean) {
        val controller = WindowCompat.getInsetsController(window, window.decorView)
        if (enabled) {
            controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            controller.hide(WindowInsetsCompat.Type.systemBars())
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        } else {
            controller.show(WindowInsetsCompat.Type.systemBars())
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        }
    }

    private fun openExternally(url: Uri) {
        try {
            startActivity(Intent(Intent.ACTION_VIEW, url).addCategory(Intent.CATEGORY_BROWSABLE))
        } catch (e: ActivityNotFoundException) {
            Toast.makeText(this, "Aucune application pour ouvrir ce lien.", Toast.LENGTH_SHORT).show()
        }
    }

    companion object {
        private const val TAG = "YoutubeActivity"
        private const val MOBILE_HOST = "m.youtube.com"
        private const val YOUTUBE_ORIGIN = "https://www.youtube.com"
        private const val BACKGROUND = 0xFF0F0F0F.toInt()

        fun open(context: Context) {
            context.startActivity(Intent(context, YoutubeActivity::class.java))
        }

        /**
         * Adresse à ouvrir pour [intent] : lien partagé, lien youtube.com ouvert avec Bouclier,
         * ou accueil de YouTube. `null` si le texte partagé ne contient aucun lien YouTube.
         */
        fun targetUrl(intent: Intent?): String? = when (intent?.action) {
            Intent.ACTION_SEND -> intent.getStringExtra(Intent.EXTRA_TEXT)
                ?.let(YoutubeLinks::findUrl)
                ?.let(YoutubeLinks::toMobileUrl)
            Intent.ACTION_VIEW -> intent.dataString?.let(YoutubeLinks::toMobileUrl)
            else -> YoutubeLinks.HOME
        }

        /** User-Agent de Chrome pour Android : celui de la WebView sans ses marques « wv » et « Version/4.0 ». */
        internal fun browserUserAgent(webViewUserAgent: String): String =
            webViewUserAgent.replace("; wv)", ")").replace(Regex(""" Version/\d+(\.\d+)*"""), "")
    }
}
