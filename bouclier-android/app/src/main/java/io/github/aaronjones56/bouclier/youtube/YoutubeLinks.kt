package io.github.aaronjones56.bouclier.youtube

import java.net.URI
import java.net.URLDecoder

/** Reconnaît les liens YouTube et les convertit en pages du site mobile, ouvertes par le lecteur sans pub. */
object YoutubeLinks {
    const val HOME = "https://m.youtube.com/"

    private val HOSTS = setOf(
        "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
        "youtu.be", "www.youtu.be", "youtube-nocookie.com", "www.youtube-nocookie.com",
    )
    private val VIDEO_ID = Regex("^[A-Za-z0-9_-]{11}$")
    private val URL_IN_TEXT = Regex("""https?://[^\s<>"']+""")

    /** Paramètres de suivi ajoutés par le bouton « Partager », inutiles au lecteur. */
    private val TRACKING_PARAMETERS = setOf("si", "feature", "pp", "app", "embeds_referring_euri", "source_ve_path")

    fun isYoutubeHost(host: String?): Boolean = host != null && host.lowercase() in HOSTS

    /** Premier lien YouTube d'un texte partagé (« Regarde ça : https://youtu.be/… »), ou `null`. */
    fun findUrl(text: String): String? =
        URL_IN_TEXT.findAll(text)
            .map { it.value.trimEnd('.', ',', ';', '!', '?', ')', ']') }
            .firstOrNull { link -> isYoutubeHost(parse(link)?.host) }

    /**
     * Page du site mobile équivalente à [link] : vidéo (avec son instant de départ et sa
     * playlist), Short, playlist, chaîne… Renvoie `null` si ce n'est pas un lien YouTube.
     */
    fun toMobileUrl(link: String): String? {
        val uri = parse(link) ?: return null
        val host = uri.host?.lowercase() ?: return null
        if (host !in HOSTS) return null
        val path = uri.rawPath.orEmpty()
        val query = parseQuery(uri.rawQuery)
        val segments = path.split('/').filter { it.isNotEmpty() }

        val videoId = when {
            host.endsWith("youtu.be") -> segments.firstOrNull()
            segments.firstOrNull() == "watch" -> query["v"]
            segments.size >= 2 && segments[0] in setOf("embed", "live", "v", "e") -> segments[1]
            else -> null
        }
        if (videoId != null) {
            if (!VIDEO_ID.matches(videoId)) return null
            val parameters = buildList {
                add("v=$videoId")
                startSeconds(query["t"] ?: query["start"])?.let { add("t=$it") }
                query["list"]?.takeIf { it.matches(Regex("^[A-Za-z0-9_-]+$")) }?.let { add("list=$it") }
            }
            return "https://m.youtube.com/watch?" + parameters.joinToString("&")
        }
        if (segments.size >= 2 && segments[0] == "shorts") {
            val id = segments[1]
            return if (VIDEO_ID.matches(id)) "https://m.youtube.com/shorts/$id" else null
        }
        // Autres pages (accueil, chaîne, playlist, recherche…) : même chemin sur le site mobile.
        val kept = query.filterKeys { it !in TRACKING_PARAMETERS }
        val queryString = if (kept.isEmpty()) "" else "?" + kept.entries.joinToString("&") { "${it.key}=${encode(it.value)}" }
        return "https://m.youtube.com" + path.ifEmpty { "/" } + queryString
    }

    /** « 90 », « 90s », « 1m30s », « 1h2m3s » → secondes. */
    internal fun startSeconds(value: String?): Int? {
        if (value.isNullOrBlank()) return null
        value.toIntOrNull()?.let { return it.takeIf { seconds -> seconds > 0 } }
        val match = Regex("""^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$""").matchEntire(value) ?: return null
        val (hours, minutes, seconds) = match.destructured
        val total = (hours.toIntOrNull() ?: 0) * 3600 + (minutes.toIntOrNull() ?: 0) * 60 + (seconds.toIntOrNull() ?: 0)
        return total.takeIf { it > 0 }
    }

    private fun parse(link: String): URI? = try {
        URI(link.trim())
    } catch (e: Exception) {
        null
    }

    private fun parseQuery(rawQuery: String?): Map<String, String> {
        if (rawQuery.isNullOrEmpty()) return emptyMap()
        val result = LinkedHashMap<String, String>()
        for (pair in rawQuery.split('&')) {
            if (pair.isEmpty()) continue
            val key = decode(pair.substringBefore('='))
            if (key.isNotEmpty() && key !in result) result[key] = decode(pair.substringAfter('=', ""))
        }
        return result
    }

    private fun decode(value: String): String = try {
        URLDecoder.decode(value, "UTF-8")
    } catch (e: IllegalArgumentException) {
        value
    }

    private fun encode(value: String): String = java.net.URLEncoder.encode(value, "UTF-8")
}
