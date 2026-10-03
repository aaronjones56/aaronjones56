package io.github.aaronjones56.bouclier.filter

import java.util.Locale

/**
 * Lit les listes de filtres aux formats les plus courants :
 *
 * - fichiers hosts : `0.0.0.0 pub.exemple.com` (plusieurs domaines possibles par ligne) ;
 * - listes de domaines : `pub.exemple.com` ou `*.pub.exemple.com` ;
 * - syntaxe Adblock adaptée au DNS : `||pub.exemple.com^`, exceptions `@@||exemple.com^`.
 *
 * Un domaine bloqué l'est aussi pour tous ses sous-domaines. Les règles qui n'ont
 * pas de sens au niveau DNS (chemins d'URL, règles cosmétiques, expressions
 * régulières, options inconnues) sont ignorées plutôt que d'être mal interprétées.
 */
object BlocklistParser {

    fun interface RuleSink {
        fun accept(domain: String, exception: Boolean)
    }

    private val NULL_ADDRESSES = setOf(
        "0.0.0.0", "127.0.0.1", "::", "::0", "::1", "0", "0:0:0:0:0:0:0:0", "0:0:0:0:0:0:0:1",
    )
    private val IGNORED_NAMES = setOf(
        "localhost", "localhost.localdomain", "local", "broadcasthost", "ip6-localhost",
        "ip6-loopback", "ip6-localnet", "ip6-mcastprefix", "ip6-allnodes", "ip6-allrouters",
        "ip6-allhosts", "0.0.0.0",
    )
    private val COSMETIC_MARKERS = arrayOf("##", "#@#", "#?#", "#$#", "#%#")

    /** Options Adblock compatibles avec un blocage DNS. */
    private val SUPPORTED_OPTIONS = setOf("important")

    /** Analyse une ligne et transmet ses règles à [sink]. */
    fun parseLine(rawLine: String, sink: RuleSink) {
        var line = rawLine.trim()
        if (line.isEmpty()) return
        when (line[0]) {
            '#', '!', '[' -> return // commentaires et en-têtes
        }
        if (COSMETIC_MARKERS.any { line.contains(it) }) return
        val comment = line.indexOf('#')
        if (comment > 0) line = line.substring(0, comment).trim()

        if (line.startsWith("@@")) {
            parseAdblockDomain(line.substring(2))?.let { sink.accept(it, exception = true) }
            return
        }
        if (line.startsWith("||")) {
            parseAdblockDomain(line)?.let { sink.accept(it, exception = false) }
            return
        }
        if (line[0] == '/' || line[0] == '|') return // expressions régulières, URL ancrées

        val separator = line.indexOfFirst { it == ' ' || it == '\t' }
        if (separator < 0) {
            normalizeDomain(line)?.let { sink.accept(it, exception = false) }
            return
        }
        // Format hosts : seules les adresses « nulles » signifient un blocage.
        if (line.substring(0, separator) !in NULL_ADDRESSES) return
        for (token in line.substring(separator + 1).split(' ', '\t')) {
            if (token.isNotEmpty()) normalizeDomain(token)?.let { sink.accept(it, exception = false) }
        }
    }

    /** Analyse un texte complet ; pratique pour les tests et les petites listes. */
    fun parse(text: String, sink: RuleSink) {
        text.lineSequence().forEach { parseLine(it, sink) }
    }

    /** Extrait le domaine d'une règle `||domaine^`, ou `null` si la règle ne vise pas un domaine entier. */
    private fun parseAdblockDomain(rule: String): String? {
        if (!rule.startsWith("||")) return null
        var body = rule.substring(2)
        val dollar = body.indexOf('$')
        if (dollar >= 0) {
            val options = body.substring(dollar + 1).split(',')
            if (options.any { it.trim().lowercase(Locale.ROOT) !in SUPPORTED_OPTIONS }) return null
            body = body.substring(0, dollar)
        }
        val caret = body.indexOf('^')
        val domain = if (caret >= 0) {
            val rest = body.substring(caret + 1)
            if (rest.isNotEmpty() && rest != "|") return null
            body.substring(0, caret)
        } else {
            body
        }
        if (domain.any { it == '/' || it == '*' || it == '|' || it == ':' || it == '?' || it == '=' }) return null
        return normalizeDomain(domain)
    }

    /**
     * Met [input] en forme (minuscules, sans point final ni préfixe `*.`) et vérifie
     * que c'est un nom de domaine plausible ; renvoie `null` sinon.
     */
    fun normalizeDomain(input: String): String? {
        var domain = input.trim().lowercase(Locale.ROOT)
        if (domain.startsWith("*.")) domain = domain.substring(2)
        if (domain.endsWith('.')) domain = domain.dropLast(1)
        if (domain.length < 3 || domain.length > 253) return null
        if ('.' !in domain || domain in IGNORED_NAMES) return null
        if (domain.startsWith('.') || domain.startsWith('-') || domain.contains("..")) return null
        for (c in domain) {
            if (c !in 'a'..'z' && c !in '0'..'9' && c != '-' && c != '.' && c != '_') return null
        }
        // Une adresse IPv4 n'est pas un nom de domaine.
        if (domain.all { it in '0'..'9' || it == '.' }) return null
        return domain
    }

    /**
     * Extrait un domaine d'une saisie libre : URL complète, domaine avec chemin,
     * port, etc. Utilisé pour les règles ajoutées à la main.
     */
    fun domainFromUserInput(input: String): String? {
        var text = input.trim()
        val scheme = text.indexOf("://")
        if (scheme >= 0) text = text.substring(scheme + 3)
        text = text.substringBefore('/').substringBefore('?').substringBefore('#')
        text = text.substringAfterLast('@').substringBefore(':')
        return normalizeDomain(text)
    }
}
