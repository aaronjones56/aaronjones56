package io.github.aaronjones56.bouclier.filter

import android.content.Context
import android.content.SharedPreferences
import android.util.AtomicFile
import android.util.Log
import androidx.core.content.edit
import io.github.aaronjones56.bouclier.AppScope
import io.github.aaronjones56.bouclier.BuildConfig
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import java.net.UnknownHostException
import java.util.concurrent.ConcurrentHashMap
import javax.net.ssl.SSLException

/** État d'une liste de filtres, tel qu'affiché dans l'application. */
data class FilterListState(
    val info: FilterListInfo,
    val enabled: Boolean,
    val domainCount: Int,
    val updatedAt: Long,
    val downloading: Boolean,
    val error: String?,
)

/** Domaines bloqués ou autorisés à la main par l'utilisateur. */
data class UserRules(val blocked: Set<String>, val allowed: Set<String>)

/** Bilan d'une mise à jour : listes téléchargées, en échec, et nombre de listes concernées. */
data class UpdateResult(val updated: Int, val failed: Int, val checked: Int)

/**
 * Listes de filtres : catalogue, téléchargement, compilation en empreintes,
 * règles de l'utilisateur et filtre ([DomainMatcher]) appliqué par le VPN.
 */
object FilterRepository {
    private const val TAG = "FilterRepository"
    private const val MAX_DOWNLOAD_BYTES = 64L * 1024 * 1024

    /** Âge au-delà duquel une liste est mise à jour automatiquement. */
    const val UPDATE_INTERVAL_MS = 2L * 24 * 3600 * 1000

    private const val KEY_USER_BLOCKED = "user_blocked"
    private const val KEY_USER_ALLOWED = "user_allowed"
    private const val KEY_CUSTOM_LISTS = "custom_lists"

    private lateinit var prefs: SharedPreferences
    private lateinit var directory: File

    private val _lists = MutableStateFlow<List<FilterListState>>(emptyList())
    val lists: StateFlow<List<FilterListState>> = _lists.asStateFlow()

    private val _matcher = MutableStateFlow(DomainMatcher.EMPTY)

    /** Filtre appliqué en ce moment ; lu à chaque requête DNS. */
    val matcher: StateFlow<DomainMatcher> = _matcher.asStateFlow()

    private val _userRules = MutableStateFlow(UserRules(emptySet(), emptySet()))
    val userRules: StateFlow<UserRules> = _userRules.asStateFlow()

    private val _updating = MutableStateFlow(false)
    val updating: StateFlow<Boolean> = _updating.asStateFlow()

    private val downloading: MutableSet<String> = ConcurrentHashMap.newKeySet()
    private val errors = ConcurrentHashMap<String, String>()
    private val updateMutex = Mutex()
    private val rebuildMutex = Mutex()
    private val matcherLock = Any()

    fun init(context: Context) {
        prefs = context.getSharedPreferences("filters", Context.MODE_PRIVATE)
        directory = File(context.filesDir, "filters").apply { mkdirs() }
        val rules = UserRules(
            blocked = prefs.getStringSet(KEY_USER_BLOCKED, null).orEmpty().toSet(),
            allowed = prefs.getStringSet(KEY_USER_ALLOWED, null).orEmpty().toSet(),
        )
        _userRules.value = rules
        // La petite liste intégrée protège déjà pendant le chargement des listes compilées.
        _matcher.value = DomainMatcher(
            BuiltinBlocklist.set, HashedDomainSet.EMPTY, rules.blocked, rules.allowed, usingBuiltinList = true,
        )
        publishStates()
        AppScope.launch { rebuildMatcher() }
    }

    /** Listes intégrées suivies des listes ajoutées par l'utilisateur. */
    fun catalog(): List<FilterListInfo> = FilterCatalog.builtIn + customLists()

    private fun isEnabled(info: FilterListInfo) = prefs.getBoolean("enabled_${info.id}", info.enabledByDefault)

    private fun updatedAt(id: String) = prefs.getLong("updated_$id", 0L)

    private fun compiledFile(id: String) = File(directory, "$id.bin")

    @Synchronized
    private fun publishStates() {
        _lists.value = catalog().map { info ->
            FilterListState(
                info = info,
                enabled = isEnabled(info),
                domainCount = prefs.getInt("count_${info.id}", 0),
                updatedAt = updatedAt(info.id),
                downloading = info.id in downloading,
                error = errors[info.id],
            )
        }
    }

    fun setEnabled(id: String, enabled: Boolean) {
        prefs.edit { putBoolean("enabled_$id", enabled) }
        publishStates()
        AppScope.launch {
            if (enabled && !compiledFile(id).exists()) {
                update(force = true, only = setOf(id))
            } else {
                rebuildMatcher()
            }
        }
    }

    /** Vrai si une liste activée n'a encore jamais été téléchargée. */
    fun hasMissingLists(): Boolean = catalog().any { isEnabled(it) && !compiledFile(it.id).exists() }

    /** Vrai si une liste activée est plus ancienne que [UPDATE_INTERVAL_MS]. */
    fun isUpdateDue(now: Long = System.currentTimeMillis()): Boolean =
        catalog().any { isEnabled(it) && now - updatedAt(it.id) > UPDATE_INTERVAL_MS }

    /**
     * Télécharge les listes activées : toutes si [force], sinon seulement celles qui
     * manquent ou sont trop anciennes. [only] restreint la mise à jour à certaines listes.
     */
    suspend fun update(force: Boolean, only: Set<String>? = null): UpdateResult = withContext(Dispatchers.IO) {
        updateMutex.withLock {
            _updating.value = true
            try {
                val now = System.currentTimeMillis()
                val targets = catalog().filter { info ->
                    isEnabled(info) && (only == null || info.id in only) &&
                        (force || !compiledFile(info.id).exists() || now - updatedAt(info.id) > UPDATE_INTERVAL_MS)
                }
                var updated = 0
                var failed = 0
                for (info in targets) {
                    downloading += info.id
                    errors.remove(info.id)
                    publishStates()
                    try {
                        downloadAndCompile(info)
                        updated++
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        failed++
                        errors[info.id] = describe(e)
                        Log.w(TAG, "Échec du téléchargement de ${info.id}", e)
                    } finally {
                        downloading -= info.id
                        publishStates()
                    }
                }
                if (updated > 0) rebuildMatcher()
                UpdateResult(updated = updated, failed = failed, checked = targets.size)
            } finally {
                _updating.value = false
            }
        }
    }

    private fun downloadAndCompile(info: FilterListInfo) {
        val blocked = LongArrayBuilder(1 shl 16)
        val exceptions = LongArrayBuilder()
        val sink = BlocklistParser.RuleSink { domain, exception ->
            (if (exception) exceptions else blocked).add(DomainHash.of(domain))
        }
        for (url in info.urls) {
            download(url) { line -> BlocklistParser.parseLine(line, sink) }
        }
        if (blocked.size == 0 && exceptions.size == 0) throw IOException("Aucun domaine reconnu dans cette liste")
        val compiled = CompiledList(blocked.toSortedUnique(), exceptions.toSortedUnique())
        writeAtomically(compiledFile(info.id), compiled.encode())
        prefs.edit {
            putInt("count_${info.id}", compiled.blocked.size)
            putLong("updated_${info.id}", System.currentTimeMillis())
        }
    }

    private fun download(url: String, onLine: (String) -> Unit) {
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

    /** Relit les listes compilées et publie un nouveau filtre. */
    suspend fun rebuildMatcher() = withContext(Dispatchers.IO) {
        rebuildMutex.withLock {
            val enabled = catalog().filter { isEnabled(it) }
            val blocked = ArrayList<LongArray>()
            val exceptions = ArrayList<LongArray>()
            for (info in enabled) {
                val compiled = readCompiled(info.id) ?: continue
                blocked += compiled.blocked
                exceptions += compiled.exceptions
            }
            // Listes activées mais pas encore téléchargées : on garde la liste intégrée.
            val usingBuiltin = enabled.isNotEmpty() && blocked.isEmpty()
            val blockedSet = if (usingBuiltin) BuiltinBlocklist.set else HashedDomainSet(mergeHashes(blocked))
            val exceptionSet = HashedDomainSet(mergeHashes(exceptions))
            synchronized(matcherLock) {
                val rules = _userRules.value
                _matcher.value = DomainMatcher(blockedSet, exceptionSet, rules.blocked, rules.allowed, usingBuiltin)
            }
        }
    }

    private fun readCompiled(id: String): CompiledList? {
        val file = compiledFile(id)
        if (!file.exists()) return null
        return try {
            CompiledList.decode(AtomicFile(file).readFully())
        } catch (e: IOException) {
            Log.w(TAG, "Liste compilée illisible : $id", e)
            null
        }
    }

    private fun writeAtomically(file: File, bytes: ByteArray) {
        val atomicFile = AtomicFile(file)
        val output = atomicFile.startWrite()
        try {
            output.write(bytes)
            atomicFile.finishWrite(output)
        } catch (e: IOException) {
            atomicFile.failWrite(output)
            throw e
        }
    }

    // --- Règles de l'utilisateur ---

    /** Ajoute une règle ; renvoie le domaine retenu, ou `null` si la saisie n'est pas un domaine. */
    fun addUserRule(input: String, allow: Boolean): String? {
        val domain = BlocklistParser.domainFromUserInput(input) ?: return null
        updateUserRules { rules ->
            if (allow) {
                UserRules(blocked = rules.blocked - domain, allowed = rules.allowed + domain)
            } else {
                UserRules(blocked = rules.blocked + domain, allowed = rules.allowed - domain)
            }
        }
        return domain
    }

    fun removeUserRule(domain: String) {
        updateUserRules { UserRules(blocked = it.blocked - domain, allowed = it.allowed - domain) }
    }

    private fun updateUserRules(transform: (UserRules) -> UserRules) {
        synchronized(matcherLock) {
            val rules = transform(_userRules.value)
            prefs.edit {
                putStringSet(KEY_USER_BLOCKED, HashSet(rules.blocked))
                putStringSet(KEY_USER_ALLOWED, HashSet(rules.allowed))
            }
            _userRules.value = rules
            _matcher.value = _matcher.value.withUserRules(rules.blocked, rules.allowed)
        }
    }

    // --- Listes personnalisées ---

    private fun customLists(): List<FilterListInfo> {
        val json = prefs.getString(KEY_CUSTOM_LISTS, null) ?: return emptyList()
        return try {
            val array = JSONArray(json)
            (0 until array.length()).map { index ->
                val item = array.getJSONObject(index)
                val url = item.getString("url")
                FilterListInfo(
                    id = item.getString("id"),
                    name = item.getString("name"),
                    description = url,
                    urls = listOf(url),
                    category = FilterCategory.CUSTOM,
                    enabledByDefault = true,
                    custom = true,
                )
            }
        } catch (e: Exception) {
            Log.w(TAG, "Listes personnalisées illisibles", e)
            emptyList()
        }
    }

    private fun saveCustomLists(lists: List<FilterListInfo>) {
        val array = JSONArray()
        for (list in lists) {
            array.put(JSONObject().put("id", list.id).put("name", list.name).put("url", list.urls.first()))
        }
        prefs.edit { putString(KEY_CUSTOM_LISTS, array.toString()) }
    }

    /** Ajoute une liste personnalisée ; renvoie un message d'erreur, ou `null` si tout va bien. */
    fun addCustomList(name: String, url: String): String? {
        val address = url.trim()
        if (!address.startsWith("https://")) return "L'adresse doit commencer par https://"
        val host = try {
            URL(address).host
        } catch (e: Exception) {
            null
        }
        if (host.isNullOrEmpty()) return "Adresse invalide"
        if (catalog().any { address in it.urls }) return "Cette liste est déjà présente"
        val info = FilterListInfo(
            id = "custom_${System.currentTimeMillis()}",
            name = name.trim().ifEmpty { host },
            description = address,
            urls = listOf(address),
            category = FilterCategory.CUSTOM,
            enabledByDefault = true,
            custom = true,
        )
        saveCustomLists(customLists() + info)
        publishStates()
        AppScope.launch { update(force = true, only = setOf(info.id)) }
        return null
    }

    fun removeCustomList(id: String) {
        saveCustomLists(customLists().filterNot { it.id == id })
        compiledFile(id).delete()
        prefs.edit {
            remove("enabled_$id")
            remove("count_$id")
            remove("updated_$id")
        }
        errors.remove(id)
        publishStates()
        AppScope.launch { rebuildMatcher() }
    }

    private fun describe(e: Exception): String = when (e) {
        is UnknownHostException -> "Pas de connexion Internet"
        is SocketTimeoutException -> "Le serveur ne répond pas"
        is SSLException -> "Connexion sécurisée impossible"
        is IOException -> e.message ?: "Erreur réseau"
        else -> "Erreur inattendue"
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
