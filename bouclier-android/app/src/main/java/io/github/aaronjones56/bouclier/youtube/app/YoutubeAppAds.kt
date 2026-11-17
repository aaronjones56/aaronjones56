package io.github.aaronjones56.bouclier.youtube.app

import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.core.content.edit
import androidx.core.net.toUri
import io.github.aaronjones56.bouclier.BuildConfig
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.text.SimpleDateFormat
import java.util.ArrayDeque
import java.util.Date
import java.util.Locale

/** Bilan du blocage dans l'appli YouTube, affiché dans Bouclier. */
data class YoutubeAppStats(val adsHidden: Int = 0, val adsSkipped: Int = 0)

/**
 * Blocage des pubs dans l'application YouTube officielle, par le service d'accessibilité
 * [YoutubeAppAdService] : état, compteurs, réglages Android et rapport de détection.
 */
object YoutubeAppAds {
    const val YOUTUBE_PACKAGE = "com.google.android.youtube"
    val TARGET_PACKAGES = setOf(YOUTUBE_PACKAGE, "com.google.android.apps.youtube.music")

    private const val MAX_REPORT_ENTRIES = 40

    private lateinit var prefs: SharedPreferences

    private val _stats = MutableStateFlow(YoutubeAppStats())
    val stats: StateFlow<YoutubeAppStats> = _stats.asStateFlow()

    private val _running = MutableStateFlow(false)

    /** Vrai quand Android a lancé le service (il est activé dans les réglages d'accessibilité). */
    val running: StateFlow<Boolean> = _running.asStateFlow()

    private val reportEntries = ArrayDeque<String>()
    private var lastClues: Set<String> = emptySet()

    fun init(context: Context) {
        prefs = context.getSharedPreferences("youtube_app", Context.MODE_PRIVATE)
        _stats.value = YoutubeAppStats(prefs.getInt("hidden", 0), prefs.getInt("skipped", 0))
    }

    internal fun setRunning(running: Boolean) {
        _running.value = running
    }

    internal fun recordAdHidden() = update { it.copy(adsHidden = it.adsHidden + 1) }

    internal fun recordAdSkipped() = update { it.copy(adsSkipped = it.adsSkipped + 1) }

    @Synchronized
    private fun update(transform: (YoutubeAppStats) -> YoutubeAppStats) {
        val stats = transform(_stats.value)
        _stats.value = stats
        if (::prefs.isInitialized) {
            prefs.edit {
                putInt("hidden", stats.adsHidden)
                putInt("skipped", stats.adsSkipped)
            }
        }
    }

    /** Vrai si le service est coché dans Réglages › Accessibilité. */
    fun isEnabled(context: Context): Boolean {
        val enabled = Settings.Secure.getString(context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)
            ?: return false
        val component = ComponentName(context, YoutubeAppAdService::class.java)
        return enabled.split(':').any { ComponentName.unflattenFromString(it.trim()) == component }
    }

    /** Ouvre Réglages › Accessibilité, où l'on active « Bouclier — pubs YouTube ». */
    fun openAccessibilitySettings(context: Context) {
        open(context, Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
    }

    /** Ouvre la fiche de Bouclier, où se trouve « Autoriser les paramètres restreints » (Android 13 et plus). */
    fun openAppDetails(context: Context) {
        open(context, Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, "package:${context.packageName}".toUri()))
    }

    private fun open(context: Context, intent: Intent) {
        try {
            context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (e: ActivityNotFoundException) {
            context.startActivity(Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    // --- Rapport de détection ---

    /**
     * Note ce que le service voit quand l'écran de YouTube change d'une façon liée aux pubs :
     * seulement des identifiants de vues et des libellés publicitaires, rien d'autre de l'écran.
     */
    @Synchronized
    internal fun recordScan(scan: AdScan, now: Long = System.currentTimeMillis()) {
        if (scan.clues == lastClues || (scan.clues.isEmpty() && !scan.adShowing)) {
            lastClues = scan.clues
            return
        }
        lastClues = scan.clues
        val time = SimpleDateFormat("HH:mm:ss", Locale.FRANCE).format(Date(now))
        val verdict = if (scan.adShowing) "PUB (${scan.signals.joinToString()})" else "pas de pub détectée"
        val skip = if (scan.skipTarget != null) " · bouton Ignorer trouvé" else ""
        reportEntries.addLast("$time  $verdict$skip\n    ${scan.clues.joinToString(" | ")}")
        while (reportEntries.size > MAX_REPORT_ENTRIES) reportEntries.removeFirst()
    }

    /** Texte à partager quand une pub n'a pas été bloquée, pour adapter la détection. */
    @Synchronized
    fun report(context: Context): String = buildString {
        appendLine("Rapport Bouclier — pubs de l'appli YouTube")
        appendLine("Bouclier ${BuildConfig.VERSION_NAME} · Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
        appendLine("YouTube ${youtubeVersion(context) ?: "non installé"}")
        appendLine("Service ${if (_running.value) "actif" else "inactif"} · ${_stats.value.adsHidden} pubs masquées · ${_stats.value.adsSkipped} ignorées")
        appendLine()
        if (reportEntries.isEmpty()) {
            appendLine("Aucun élément publicitaire vu depuis le démarrage du service.")
        } else {
            reportEntries.forEach { appendLine(it) }
        }
    }

    private fun youtubeVersion(context: Context): String? = try {
        context.packageManager.getPackageInfo(YOUTUBE_PACKAGE, 0).versionName
    } catch (e: PackageManager.NameNotFoundException) {
        null
    }

    /** Partage du rapport (messagerie, e-mail, copie…). */
    fun shareReport(context: Context) {
        val send = Intent(Intent.ACTION_SEND)
            .setType("text/plain")
            .putExtra(Intent.EXTRA_SUBJECT, "Rapport Bouclier — pubs YouTube")
            .putExtra(Intent.EXTRA_TEXT, report(context))
        context.startActivity(Intent.createChooser(send, "Envoyer le rapport").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
