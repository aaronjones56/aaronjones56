package io.github.aaronjones56.bouclier.stats

import android.content.Context
import android.util.AtomicFile
import android.util.Log
import io.github.aaronjones56.bouclier.filter.Verdict
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.time.LocalDate
import java.time.LocalDateTime

/** Requête DNS vue par le VPN, pour le journal. */
data class QueryLogEntry(val time: Long, val domain: String, val type: Int, val verdict: Verdict)

/** Copie immuable des statistiques, prête à afficher. */
class StatsSnapshot(
    val version: Long,
    val todayQueries: Int,
    val todayBlocked: Int,
    val totalQueries: Long,
    val totalBlocked: Long,
    val hourlyQueries: IntArray,
    val hourlyBlocked: IntArray,
    /** Domaines les plus bloqués aujourd'hui, du plus fréquent au moins fréquent. */
    val topBlocked: List<Pair<String, Int>>,
    /** Dernières requêtes, de la plus récente à la plus ancienne. */
    val recent: List<QueryLogEntry>,
) {
    /** Estimation du trafic évité aujourd'hui (voir [StatsRepository.ESTIMATED_BYTES_PER_BLOCK]). */
    val todaySavedBytes: Long get() = todayBlocked * StatsRepository.ESTIMATED_BYTES_PER_BLOCK
    val totalSavedBytes: Long get() = totalBlocked * StatsRepository.ESTIMATED_BYTES_PER_BLOCK
}

/**
 * Compteurs de requêtes (aujourd'hui, par heure et depuis l'installation), domaines
 * les plus bloqués et journal des dernières requêtes. Le journal reste en mémoire :
 * il n'est jamais écrit sur le disque.
 */
object StatsRepository {
    /**
     * Taille moyenne estimée de ce qu'une requête bloquée aurait téléchargé (script,
     * image ou vidéo publicitaire). Il s'agit d'un ordre de grandeur, pas d'une mesure.
     */
    const val ESTIMATED_BYTES_PER_BLOCK = 60L * 1024

    private const val TAG = "StatsRepository"
    private const val MAX_RECENT = 500
    private const val MAX_TRACKED_DOMAINS = 5000
    private const val TOP_COUNT = 20

    private lateinit var file: AtomicFile
    private val lock = Any()

    // Tous les champs suivants sont protégés par [lock], sauf [version] qui se lit sans verrou.
    @Volatile
    private var version = 0L
    private var savedVersion = 0L
    private var day = LocalDate.now()
    private var todayQueries = 0
    private var todayBlocked = 0
    private var totalQueries = 0L
    private var totalBlocked = 0L
    private val hourlyQueries = IntArray(24)
    private val hourlyBlocked = IntArray(24)
    private val blockedDomains = HashMap<String, Int>()
    private val recent = ArrayDeque<QueryLogEntry>()

    fun init(context: Context) {
        file = AtomicFile(File(context.filesDir, "stats.json"))
        load()
    }

    /** Enregistre une requête ; appelé par le VPN pour chaque question DNS. */
    fun record(domain: String, type: Int, verdict: Verdict) {
        val now = LocalDateTime.now()
        synchronized(lock) {
            rollOverIfNeeded(now.toLocalDate())
            val hour = now.hour
            todayQueries++
            totalQueries++
            hourlyQueries[hour]++
            if (verdict.blocked) {
                todayBlocked++
                totalBlocked++
                hourlyBlocked[hour]++
                val count = blockedDomains[domain]
                if (count != null) {
                    blockedDomains[domain] = count + 1
                } else if (blockedDomains.size < MAX_TRACKED_DOMAINS) {
                    blockedDomains[domain] = 1
                }
            }
            recent.addFirst(QueryLogEntry(System.currentTimeMillis(), domain, type, verdict))
            if (recent.size > MAX_RECENT) recent.removeLast()
            version++
        }
    }

    fun snapshot(): StatsSnapshot = synchronized(lock) {
        rollOverIfNeeded(LocalDate.now())
        StatsSnapshot(
            version = version,
            todayQueries = todayQueries,
            todayBlocked = todayBlocked,
            totalQueries = totalQueries,
            totalBlocked = totalBlocked,
            hourlyQueries = hourlyQueries.copyOf(),
            hourlyBlocked = hourlyBlocked.copyOf(),
            topBlocked = blockedDomains.entries
                .sortedByDescending { it.value }
                .take(TOP_COUNT)
                .map { it.key to it.value },
            recent = recent.toList(),
        )
    }

    /**
     * Statistiques vérifiées toutes les [periodMs] millisecondes et émises seulement quand
     * elles ont changé (la copie n'est pas recalculée tant que rien ne bouge).
     */
    fun snapshots(periodMs: Long): Flow<StatsSnapshot> = flow {
        var lastVersion = -1L
        var lastDay = LocalDate.now()
        while (true) {
            val today = LocalDate.now()
            if (version != lastVersion || today != lastDay) {
                val snapshot = snapshot()
                lastVersion = snapshot.version
                lastDay = today
                emit(snapshot)
            }
            delay(periodMs)
        }
    }

    /** Remet tous les compteurs à zéro. */
    fun reset() {
        synchronized(lock) {
            day = LocalDate.now()
            clearToday()
            totalQueries = 0
            totalBlocked = 0
            recent.clear()
            version++
        }
        save()
    }

    private fun rollOverIfNeeded(today: LocalDate) {
        if (today != day) {
            day = today
            clearToday()
            version++
        }
    }

    private fun clearToday() {
        todayQueries = 0
        todayBlocked = 0
        hourlyQueries.fill(0)
        hourlyBlocked.fill(0)
        blockedDomains.clear()
    }

    /** Écrit les compteurs sur le disque s'ils ont changé depuis la dernière sauvegarde. */
    fun save() {
        val json: String
        synchronized(lock) {
            if (version == savedVersion) return
            savedVersion = version
            json = JSONObject()
                .put("day", day.toString())
                .put("todayQueries", todayQueries)
                .put("todayBlocked", todayBlocked)
                .put("totalQueries", totalQueries)
                .put("totalBlocked", totalBlocked)
                .put("hourlyQueries", JSONArray(hourlyQueries.toList()))
                .put("hourlyBlocked", JSONArray(hourlyBlocked.toList()))
                .put("blockedDomains", JSONObject(blockedDomains.toMap()))
                .toString()
        }
        try {
            val output = file.startWrite()
            try {
                output.write(json.toByteArray())
                file.finishWrite(output)
            } catch (e: IOException) {
                file.failWrite(output)
                throw e
            }
        } catch (e: IOException) {
            Log.w(TAG, "Impossible d'enregistrer les statistiques", e)
        }
    }

    private fun load() {
        val json = try {
            JSONObject(String(file.readFully()))
        } catch (e: Exception) {
            return // premier lancement ou fichier illisible
        }
        synchronized(lock) {
            totalQueries = json.optLong("totalQueries")
            totalBlocked = json.optLong("totalBlocked")
            val savedDay = runCatching { LocalDate.parse(json.optString("day")) }.getOrNull()
            if (savedDay != null && savedDay == LocalDate.now()) {
                day = savedDay
                todayQueries = json.optInt("todayQueries")
                todayBlocked = json.optInt("todayBlocked")
                readInts(json.optJSONArray("hourlyQueries"), hourlyQueries)
                readInts(json.optJSONArray("hourlyBlocked"), hourlyBlocked)
                json.optJSONObject("blockedDomains")?.let { domains ->
                    for (key in domains.keys()) blockedDomains[key] = domains.optInt(key)
                }
            }
            version++
            savedVersion = version
        }
    }

    private fun readInts(array: JSONArray?, target: IntArray) {
        if (array == null) return
        for (i in 0 until minOf(array.length(), target.size)) target[i] = array.optInt(i)
    }
}
