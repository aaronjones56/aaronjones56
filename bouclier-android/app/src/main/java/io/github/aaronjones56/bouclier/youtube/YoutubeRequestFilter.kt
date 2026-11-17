package io.github.aaronjones56.bouclier.youtube

import io.github.aaronjones56.bouclier.filter.DomainMatcher
import java.net.URI

/**
 * Requêtes à bloquer dans le lecteur YouTube : domaines des listes de filtres (régies,
 * traqueurs), adresses que YouTube réserve aux publicités et règles réseau des listes
 * AdGuard et uBlock Origin.
 */
object YoutubeRequestFilter {

    /** Chemins publicitaires sur les domaines YouTube (statistiques et suivi des annonces). */
    private val AD_PATHS = listOf(
        "/api/stats/ads",
        "/api/stats/atr",
        "/pagead/",
        "/ptracking",
        "/get_midroll_info",
        "/pcs/activeview",
        "/youtubei/v1/player/ad_break",
    )

    fun shouldBlock(url: String, matcher: DomainMatcher, rules: List<Regex> = emptyList()): Boolean {
        val uri = try {
            URI(url)
        } catch (e: Exception) {
            return false
        }
        val host = uri.host?.lowercase() ?: return false
        if (matcher.verdict(host).blocked) return true
        if (host == "youtube.com" || host.endsWith(".youtube.com")) {
            val path = uri.rawPath.orEmpty()
            if (AD_PATHS.any { path.startsWith(it) }) return true
        }
        return rules.any { it.containsMatchIn(url) }
    }
}
