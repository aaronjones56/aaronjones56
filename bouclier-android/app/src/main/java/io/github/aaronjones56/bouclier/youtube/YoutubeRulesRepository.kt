package io.github.aaronjones56.bouclier.youtube

import android.content.Context
import android.content.SharedPreferences
import android.util.AtomicFile
import android.util.Log
import androidx.core.content.edit
import io.github.aaronjones56.bouclier.AppScope
import io.github.aaronjones56.bouclier.BuildConfig
import io.github.aaronjones56.bouclier.filter.FilterRepository
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL

/** État des règles YouTube, tel qu'affiché dans les paramètres. */
data class YoutubeRulesState(
    val ruleCount: Int = 0,
    /** Date du dernier téléchargement réussi ; 0 : règles fournies avec l'application. */
    val updatedAt: Long = 0L,
    val updating: Boolean = false,
    val error: String? = null,
)

/** Ce que le lecteur YouTube applique : scripts injectés au démarrage des pages et adresses bloquées. */
class YoutubePlayerRules(val scripts: List<String>, val blockedUrls: List<Regex>)

/**
 * Règles anti-pub YouTube des extensions de navigateur : celles d'AdGuard (AdGuard Base, version
 * pour extensions Chromium) et d'uBlock Origin (uBlock filters et Quick fixes), exécutées par la
 * bibliothèque AdGuard Scriptlets. Des règles sont fournies avec l'application ; les listes sont
 * ensuite retéléchargées régulièrement, comme dans les extensions, pour suivre les changements
 * de YouTube. Seules les lignes qui concernent YouTube sont gardées sur le téléphone.
 */
object YoutubeRulesRepository {
    private const val TAG = "YoutubeRules"
    private const val MAX_DOWNLOAD_BYTES = 32L * 1024 * 1024

    /** Âge au-delà duquel les règles sont retéléchargées à l'ouverture du lecteur. */
    const val UPDATE_INTERVAL_MS = 12L * 3600 * 1000

    internal class Source(val id: String, val name: String, val urls: List<String>, val asset: String, val platform: Set<String>)

    internal val SOURCES = listOf(
        Source(
            id = "adguard",
            name = "AdGuard Base",
            urls = listOf("https://filters.adtidy.org/extension/chromium/filters/2_optimized.txt"),
            asset = "youtube/default-rules-adguard.txt",
            platform = YoutubeRuleParser.ADGUARD_PLATFORM,
        ),
        Source(
            id = "ubo",
            name = "uBlock Origin",
            urls = listOf(
                "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/filters.txt",
                "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/quick-fixes.txt",
            ),
            asset = "youtube/default-rules-ubo.txt",
            platform = YoutubeRuleParser.UBO_PLATFORM,
        ),
    )

    private lateinit var appContext: Context
    private lateinit var prefs: SharedPreferences
    private lateinit var directory: File

    private val _state = MutableStateFlow(YoutubeRulesState())
    val state: StateFlow<YoutubeRulesState> = _state.asStateFlow()

    private val _playerRules = MutableStateFlow<YoutubePlayerRules?>(null)

    /** Règles du lecteur ; `null` pendant leur tout premier chargement. */
    val playerRules: StateFlow<YoutubePlayerRules?> = _playerRules.asStateFlow()

    private val updateMutex = Mutex()
    private val reloadMutex = Mutex()

    private val builtInScript: String by lazy { readAsset("youtube/adblock.js") }

    private val library: ScriptletLibrary by lazy {
        try {
            scriptletLibraryFromJson(readAsset("youtube/scriptlets.corelibs.json"))
        } catch (e: Exception) {
            Log.e(TAG, "Bibliothèque de scriptlets illisible", e)
            ScriptletLibrary.of("", emptyList())
        }
    }

    fun init(context: Context) {
        appContext = context.applicationContext
        prefs = appContext.getSharedPreferences("youtube_rules", Context.MODE_PRIVATE)
        directory = File(appContext.filesDir, "youtube-rules").apply { mkdirs() }
        _state.value = YoutubeRulesState(updatedAt = lastUpdate())
        AppScope.launch { reload() }
    }

    private fun lastUpdate(): Long = SOURCES.maxOf { prefs.getLong("updated_${it.id}", 0L) }

    private fun storedFile(source: Source) = File(directory, "${source.id}.txt")

    /** Vrai si une liste n'a pas été téléchargée depuis [UPDATE_INTERVAL_MS]. */
    fun isUpdateDue(now: Long = System.currentTimeMillis()): Boolean =
        SOURCES.any { now - prefs.getLong("updated_${it.id}", 0L) > UPDATE_INTERVAL_MS }

    /** Lance une mise à jour en arrière-plan si les règles ont vieilli. */
    fun updateIfDue() {
        if (isUpdateDue() && !_state.value.updating) AppScope.launch { update(force = false) }
    }

    /**
     * Retélécharge les listes (toutes si [force], sinon les trop anciennes) et applique les
     * nouvelles règles. Renvoie le nombre de listes en échec.
     */
    suspend fun update(force: Boolean): Int = withContext(Dispatchers.IO) {
        updateMutex.withLock {
            _state.update { it.copy(updating = true, error = null) }
            var failed = 0
            var lastError: String? = null
            try {
                val now = System.currentTimeMillis()
                for (source in SOURCES) {
                    if (!force && now - prefs.getLong("updated_${source.id}", 0L) <= UPDATE_INTERVAL_MS) continue
                    try {
                        download(source)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        failed++
                        lastError = "${source.name} : ${FilterRepository.describe(e)}"
                        Log.w(TAG, "Échec du téléchargement de ${source.id}", e)
                    }
                }
                reload()
            } finally {
                _state.update { it.copy(updating = false, error = lastError, updatedAt = lastUpdate()) }
            }
            failed
        }
    }

    private fun download(source: Source) {
        val extractor = YoutubeRuleParser.Extractor(source.platform)
        for (url in source.urls) downloadLines(url, extractor::accept)
        val lines = extractor.lines()
        val rules = YoutubeRuleParser.parse(lines.joinToString("\n"), trusted = true)
        // Liste tronquée ou format changé : on garde les règles précédentes.
        if (rules.scriptlets.isEmpty()) throw IOException("Aucune règle YouTube dans la liste")
        val text = buildString {
            append("! ").append(source.name).append(" : règles qui visent ").append(YoutubeRuleParser.HOST).append('\n')
            lines.forEach { append(it).append('\n') }
        }
        val file = AtomicFile(storedFile(source))
        val output = file.startWrite()
        try {
            output.write(text.toByteArray())
            file.finishWrite(output)
        } catch (e: IOException) {
            file.failWrite(output)
            throw e
        }
        prefs.edit { putLong("updated_${source.id}", System.currentTimeMillis()) }
    }

    private fun downloadLines(url: String, onLine: (String) -> Unit) {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.connectTimeout = 15_000
        connection.readTimeout = 30_000
        connection.setRequestProperty("User-Agent", "Bouclier/${BuildConfig.VERSION_NAME} (Android)")
        try {
            val code = connection.responseCode
            if (code !in 200..299) throw IOException("Le serveur a répondu $code")
            LimitedInputStream(connection.inputStream, MAX_DOWNLOAD_BYTES).bufferedReader().use { reader ->
                while (true) onLine(reader.readLine() ?: break)
            }
        } finally {
            connection.disconnect()
        }
    }

    /** Relit les règles enregistrées (ou fournies) et publie les scripts du lecteur. */
    suspend fun reload() = withContext(Dispatchers.IO) {
        reloadMutex.withLock {
            var rules = YoutubeRules()
            for (source in SOURCES) {
                val text = readStored(source) ?: readAsset(source.asset)
                rules += YoutubeRuleParser.parse(text, trusted = true, platform = source.platform)
            }
            val scripts = YoutubeScriptBuilder.build(builtInScript, rules, library)
            val blocked = rules.blockedUrls.mapNotNull { pattern ->
                try {
                    Regex(pattern, RegexOption.IGNORE_CASE)
                } catch (e: IllegalArgumentException) {
                    null
                }
            }
            _playerRules.value = YoutubePlayerRules(scripts, blocked)
            _state.update { it.copy(ruleCount = rules.size) }
        }
    }

    private fun readStored(source: Source): String? {
        val file = storedFile(source)
        if (!file.exists()) return null
        return try {
            String(AtomicFile(file).readFully())
        } catch (e: IOException) {
            Log.w(TAG, "Règles illisibles : ${source.id}", e)
            null
        }
    }

    private fun readAsset(path: String): String = appContext.assets.open(path).bufferedReader().use { it.readText() }

    /** Bibliothèque au format « corelibs » d'AdGuard : `{ version, scriptlets: [{ names, scriptlet }] }`. */
    internal fun scriptletLibraryFromJson(json: String): ScriptletLibrary {
        val root = JSONObject(json)
        val array = root.getJSONArray("scriptlets")
        val entries = (0 until array.length()).map { index ->
            val item = array.getJSONObject(index)
            val names = item.getJSONArray("names")
            (0 until names.length()).map { names.getString(it) } to item.getString("scriptlet")
        }
        return ScriptletLibrary.of(root.optString("version"), entries)
    }

    /** Coupe le téléchargement d'une liste anormalement volumineuse. */
    private class LimitedInputStream(input: InputStream, private val limit: Long) : FilterInputStream(input) {
        private var total = 0L

        override fun read(): Int {
            val value = super.read()
            if (value >= 0) count(1)
            return value
        }

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
            val read = super.read(buffer, offset, length)
            if (read > 0) count(read.toLong())
            return read
        }

        private fun count(bytes: Long) {
            total += bytes
            if (total > limit) throw IOException("Liste trop volumineuse")
        }
    }
}
