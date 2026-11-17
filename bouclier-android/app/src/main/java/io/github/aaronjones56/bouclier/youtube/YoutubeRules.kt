package io.github.aaronjones56.bouclier.youtube

/** Appel d'un « scriptlet » : fonction des bloqueurs exécutée dans la page avec ses arguments. */
data class ScriptletCall(val name: String, val args: List<String>, val ruleText: String) {
    internal val key: String get() = (listOf(name) + args).joinToString("\u0000")

    /** Scriptlet réservé aux listes de confiance : il peut réécrire n'importe quelle réponse. */
    internal val isTrusted: Boolean get() = name.startsWith("trusted-")
}

/** Règles des listes de filtres (AdGuard, uBlock Origin) applicables au site mobile de YouTube. */
data class YoutubeRules(
    val scriptlets: List<ScriptletCall> = emptyList(),
    /** JavaScript fourni tel quel par une liste de confiance (AdGuard). */
    val scripts: List<String> = emptyList(),
    /** Sélecteurs CSS des éléments à masquer. */
    val hiddenSelectors: List<String> = emptyList(),
    /** Expressions régulières des adresses à bloquer. */
    val blockedUrls: List<String> = emptyList(),
) {
    val size: Int get() = scriptlets.size + scripts.size + hiddenSelectors.size + blockedUrls.size

    /** Fusion sans doublon, dans l'ordre des listes. */
    operator fun plus(other: YoutubeRules) = YoutubeRules(
        scriptlets = (scriptlets + other.scriptlets).distinctBy { it.key },
        scripts = (scripts + other.scripts).distinct(),
        hiddenSelectors = (hiddenSelectors + other.hiddenSelectors).distinct(),
        blockedUrls = (blockedUrls + other.blockedUrls).distinct(),
    )
}

/**
 * Lit les listes de filtres au format AdGuard et uBlock Origin et garde les règles qui
 * s'appliquent à [HOST] :
 *
 * - scriptlets : `domaines#%#//scriptlet('nom', 'arg')` (AdGuard) et `domaines##+js(nom, arg)`
 *   (uBlock Origin, pour les fonctions dont les arguments ont le même sens chez AdGuard) ;
 * - JavaScript brut `domaines#%#code`, seulement depuis une liste de confiance ;
 * - masquage CSS `domaines##sélecteur` (hors syntaxes étendues propres aux extensions) ;
 * - règles réseau `||youtube.com/chemin` : blocage, ou réécriture de réponse (`replace=`).
 *
 * Les exceptions (`#@#`, `#@%#`), les règles annulées (`badfilter`) et les blocs
 * conditionnels (`!#if … !#else … !#endif`) sont respectés. Les règles génériques, valables
 * pour tous les sites, sont ignorées : seules celles qui citent YouTube sont utiles ici.
 */
object YoutubeRuleParser {
    const val HOST = "m.youtube.com"

    /** Constantes vraies dans les blocs `!#if` des listes d'AdGuard (extension pour Chromium). */
    val ADGUARD_PLATFORM = setOf("adguard", "adguard_ext_chromium")

    /** Constantes vraies dans les blocs `!#if` des listes d'uBlock Origin (Chromium, mobile). */
    val UBO_PLATFORM = setOf("ext_ublock", "env_chromium", "env_mobile", "cap_user_stylesheet")
    private val YOUTUBE_HOSTS = setOf("youtube.com", "m.youtube.com")

    private val MARKER = Regex("""#@?(?:%|\$\??|\?)?#""")

    /** Pseudo-classes des syntaxes étendues, que le CSS du navigateur ne comprend pas. */
    private val PROCEDURAL = listOf(
        ":has-text(", ":upward(", ":xpath(", ":remove(", ":style(", ":matches-css", ":min-text-length(",
        ":watch-attr(", ":others(", ":matches-path(", ":matches-attr(", ":matches-prop(", ":-abp-",
        ":contains(", ":if(", ":if-not(", ":remove-attr(", ":remove-class(", ":matches-media(", ":shadow",
    )

    /** Fonctions uBlock Origin dont les arguments ont le même sens chez AdGuard. */
    private val UBO_SCRIPTLETS = mapOf(
        "set" to "set-constant",
        "set-constant" to "set-constant",
        "json-prune" to "json-prune",
        "json-prune-fetch-response" to "json-prune-fetch-response",
        "json-prune-xhr-response" to "json-prune-xhr-response",
        "trusted-rpfr" to "trusted-replace-fetch-response",
        "trusted-replace-fetch-response" to "trusted-replace-fetch-response",
        "trusted-replace-xhr-response" to "trusted-replace-xhr-response",
        "rmnt" to "remove-node-text",
        "remove-node-text" to "remove-node-text",
    )

    /** Fonctions uBlock Origin à arguments nommés (`propsToMatch, valeur`) en fin de liste. */
    private val UBO_NAMED_ARGUMENTS = setOf("json-prune", "json-prune-fetch-response", "json-prune-xhr-response")

    /** Modificateurs réseau compatibles avec un simple blocage d'adresse. */
    private val NETWORK_OPTIONS = setOf(
        "xhr", "xmlhttprequest", "script", "image", "media", "other", "fetch", "1p", "first-party",
        "~third-party", "important", "all",
    )

    /**
     * Règles de [text] applicables à [HOST]. [trusted] : la liste peut fournir du JavaScript
     * brut (règles `#%#` hors scriptlets), des scriptlets « trusted-… » et des réécritures de
     * réponse, comme les listes officielles dans les extensions. [platform] : constantes
     * vraies dans les blocs conditionnels.
     */
    fun parse(text: String, trusted: Boolean, platform: Set<String> = emptySet()): YoutubeRules {
        val scriptlets = LinkedHashMap<String, ScriptletCall>()
        val scriptletExceptions = HashSet<String>()
        val scripts = LinkedHashSet<String>()
        val scriptExceptions = HashSet<String>()
        val selectors = LinkedHashSet<String>()
        val selectorExceptions = HashSet<String>()
        val network = LinkedHashMap<String, NetworkRule>()
        val cancelled = HashSet<String>()

        val preprocessor = Preprocessor(platform)
        for (raw in text.lineSequence()) {
            val line = raw.trim()
            if (!preprocessor.isActive(line)) continue
            if (line.isEmpty() || line[0] == '!' || line[0] == '[') continue
            if (line.startsWith("||") || line.startsWith("@@")) {
                val rule = parseNetwork(line, trusted) ?: continue
                if (rule.badfilter) {
                    cancelled += rule.key
                } else {
                    network[rule.key] = rule
                }
                continue
            }
            val marker = MARKER.find(line) ?: continue
            if (!appliesToHost(line.substring(0, marker.range.first))) continue
            val body = line.substring(marker.range.last + 1)
            when (marker.value) {
                "##" -> when {
                    body.startsWith("+js(") ->
                        parseUboScriptlet(body, line)?.takeIf { trusted || !it.isTrusted }?.let { scriptlets[it.key] = it }
                    body.startsWith("^") -> Unit // filtrage HTML propre à uBlock Origin
                    isPlainSelector(body) -> selectors += body
                }
                "#@#" -> when {
                    body.startsWith("+js(") -> parseUboScriptlet(body, line)?.let { scriptletExceptions += it.key }
                    else -> selectorExceptions += body
                }
                "#%#" -> when {
                    body.startsWith("//scriptlet(") ->
                        parseAdguardScriptlet(body, line)?.takeIf { trusted || !it.isTrusted }?.let { scriptlets[it.key] = it }
                    trusted && body.isNotBlank() -> scripts += body
                }
                "#@%#" -> when {
                    body.startsWith("//scriptlet(") -> parseAdguardScriptlet(body, line)?.let { scriptletExceptions += it.key }
                    else -> scriptExceptions += body
                }
            }
        }

        val activeNetwork = network.values.filter { it.key !in cancelled }
        val replacements = activeNetwork.mapNotNull { it.replace }.flatMap { it.scriptlets }
        return YoutubeRules(
            scriptlets = (scriptlets.values.filter { it.key !in scriptletExceptions } + replacements).distinctBy { it.key },
            scripts = scripts.filter { it !in scriptExceptions },
            hiddenSelectors = selectors.filter { it !in selectorExceptions },
            blockedUrls = activeNetwork.filter { it.replace == null }.map { it.regex }.distinct(),
        )
    }

    /**
     * Lignes de [text] qui concernent [HOST], blocs conditionnels résolus pour [platform] :
     * de quoi garder un extrait léger d'une grande liste.
     */
    fun relevantLines(text: String, platform: Set<String>): List<String> {
        val extractor = Extractor(platform)
        text.lineSequence().forEach(extractor::accept)
        return extractor.lines()
    }

    /** Extraction ligne à ligne, pour lire une grande liste pendant son téléchargement. */
    class Extractor(platform: Set<String>) {
        private val preprocessor = Preprocessor(platform)
        private val kept = LinkedHashSet<String>()

        fun accept(raw: String) {
            val line = raw.trim()
            if (preprocessor.isActive(line) && isRelevant(line)) kept += line
        }

        fun lines(): List<String> = kept.toList()
    }

    private fun isRelevant(line: String): Boolean = when {
        line.isEmpty() || line[0] == '!' || line[0] == '[' || !line.contains("youtube") -> false
        line.startsWith("||") || line.startsWith("@@") -> youtubeNetworkPattern(line.removePrefix("@@"))
        else -> MARKER.find(line)?.let { appliesToHost(line.substring(0, it.range.first)) } == true
    }

    /**
     * Blocs conditionnels des listes : `!#if (adguard_ext_chromium || env_mobile)`, `!#else`,
     * `!#endif`. Une expression illisible est fausse ; `!#include` est ignoré.
     */
    internal class Preprocessor(private val platform: Set<String>) {
        private val conditions = ArrayList<Boolean>()

        /** Vrai si [line] (sans espaces autour) est une ligne de règle à prendre en compte. */
        fun isActive(line: String): Boolean {
            if (!line.startsWith("!#")) return conditions.all { it }
            when {
                line.startsWith("!#if") -> conditions += evaluate(line.removePrefix("!#if"))
                line.startsWith("!#else") -> if (conditions.isNotEmpty()) conditions[conditions.lastIndex] = !conditions.last()
                line.startsWith("!#endif") -> if (conditions.isNotEmpty()) conditions.removeAt(conditions.lastIndex)
            }
            return false
        }

        private fun evaluate(expression: String): Boolean {
            val tokens = TOKEN.findAll(expression).map { it.value }.toList()
            if (tokens.joinToString("") != expression.filterNot { it.isWhitespace() }) return false
            return try {
                val parser = ExpressionParser(tokens, platform)
                parser.or().also { if (!parser.done) throw IllegalArgumentException() }
            } catch (e: IllegalArgumentException) {
                false
            }
        }

        private class ExpressionParser(private val tokens: List<String>, private val platform: Set<String>) {
            private var position = 0
            val done: Boolean get() = position == tokens.size

            private fun peek() = tokens.getOrNull(position)

            fun or(): Boolean {
                var value = and()
                while (peek() == "||") {
                    position++
                    value = and() or value
                }
                return value
            }

            private fun and(): Boolean {
                var value = unary()
                while (peek() == "&&") {
                    position++
                    value = unary() and value
                }
                return value
            }

            private fun unary(): Boolean {
                val token = peek() ?: throw IllegalArgumentException()
                position++
                return when (token) {
                    "!" -> !unary()
                    "(" -> or().also { if (peek() != ")") throw IllegalArgumentException() else position++ }
                    "&&", "||", ")" -> throw IllegalArgumentException()
                    else -> token in platform
                }
            }
        }

        private companion object {
            val TOKEN = Regex("""\|\||&&|[!()]|[A-Za-z0-9_]+""")
        }
    }

    /** Vrai si la liste de domaines d'une règle cosmétique inclut [HOST] (et ne l'exclut pas). */
    internal fun appliesToHost(domains: String): Boolean {
        var included = false
        for (entry in domains.split(',')) {
            val domain = entry.trim().lowercase()
            if (domain.isEmpty()) continue
            val negated = domain.startsWith('~')
            if (!matchesHost(domain.removePrefix("~"))) continue
            if (negated) return false
            included = true
        }
        return included
    }

    private fun matchesHost(domain: String): Boolean = when {
        domain.endsWith(".*") -> Regex("(^|\\.)" + Regex.escape(domain.dropLast(2)) + "\\.[a-z.]+$").containsMatchIn(HOST)
        else -> HOST == domain || HOST.endsWith(".$domain")
    }

    private fun isPlainSelector(selector: String): Boolean =
        selector.isNotBlank() && PROCEDURAL.none { selector.contains(it) }

    // --- Scriptlets ---

    private fun parseAdguardScriptlet(body: String, ruleText: String): ScriptletCall? {
        if (!body.endsWith(")")) return null
        val tokens = parseQuotedArguments(body.substring("//scriptlet(".length, body.length - 1)) ?: return null
        val name = tokens.firstOrNull()?.takeIf { it.isNotBlank() } ?: return null
        return ScriptletCall(name, tokens.drop(1), ruleText)
    }

    private fun parseUboScriptlet(body: String, ruleText: String): ScriptletCall? {
        if (!body.endsWith(")")) return null
        val tokens = splitUboArguments(body.substring("+js(".length, body.length - 1))
        val uboName = tokens.firstOrNull()?.removeSuffix(".js") ?: return null
        val name = UBO_SCRIPTLETS[uboName] ?: return null
        var args = tokens.drop(1)
        if (uboName in UBO_NAMED_ARGUMENTS) args = convertUboNamedArguments(uboName, args) ?: return null
        return ScriptletCall(name, args, ruleText)
    }

    /** Arguments AdGuard : chaînes entre apostrophes ou guillemets, séparées par des virgules. */
    internal fun parseQuotedArguments(text: String): List<String>? {
        val result = mutableListOf<String>()
        var i = 0
        while (i < text.length) {
            val c = text[i]
            when {
                c == ' ' || c == ',' -> i++
                c == '\'' || c == '"' -> {
                    val value = StringBuilder()
                    i++
                    while (i < text.length && text[i] != c) {
                        if (text[i] == '\\' && i + 1 < text.length && text[i + 1] == c) {
                            value.append(c)
                            i += 2
                        } else {
                            value.append(text[i++])
                        }
                    }
                    if (i >= text.length) return null // guillemet non refermé
                    i++
                    result += value.toString()
                }
                else -> return null
            }
        }
        return result
    }

    /** Arguments uBlock Origin : séparés par des virgules (« \, » pour une virgule littérale). */
    internal fun splitUboArguments(text: String): List<String> {
        val parts = mutableListOf<String>()
        val current = StringBuilder()
        var i = 0
        while (i < text.length) {
            val c = text[i]
            when {
                c == '\\' && i + 1 < text.length && text[i + 1] == ',' -> {
                    current.append(',')
                    i += 2
                    continue
                }
                c == ',' -> {
                    parts += current.toString()
                    current.clear()
                }
                else -> current.append(c)
            }
            i++
        }
        parts += current.toString()
        return parts.map { unquote(it.trim()) }
    }

    private fun unquote(value: String): String {
        if (value.length >= 2 && value.first() == value.last() && value.first() in "'\"`") {
            return value.substring(1, value.length - 1)
        }
        return value
    }

    /**
     * uBlock Origin : `json-prune-fetch-response, chemins, requis, propsToMatch, /url/` ;
     * AdGuard : `json-prune-fetch-response, chemins, requis, /url/` (arguments par position).
     */
    private fun convertUboNamedArguments(name: String, args: List<String>): List<String>? {
        if (args.size <= 2) return args
        val positional = args.take(2).toMutableList()
        while (positional.size < 2) positional += ""
        val named = args.drop(2)
        if (named.size % 2 != 0) return null
        var propsToMatch = ""
        var stack = ""
        for ((key, value) in named.chunked(2).map { it[0] to it[1] }) {
            when (key) {
                "propsToMatch" -> propsToMatch = value
                "stackToMatch" -> stack = value
                else -> return null
            }
        }
        return if (name == "json-prune") {
            if (propsToMatch.isNotEmpty()) null else positional + listOfNotNull(stack.ifEmpty { null })
        } else {
            positional + propsToMatch + listOfNotNull(stack.ifEmpty { null })
        }
    }

    // --- Règles réseau ---

    private class NetworkRule(val key: String, val regex: String, val badfilter: Boolean, val replace: Replacement?)

    /** Réécriture de réponse (`replace=/motif/remplacement/`), faite par deux scriptlets. */
    private class Replacement(val scriptlets: List<ScriptletCall>)

    private fun youtubeNetworkPattern(rule: String): Boolean {
        if (!rule.startsWith("||")) return false
        val host = rule.substring(2).split('/', '^', '*', '$', '|').first().lowercase()
        return host in YOUTUBE_HOSTS
    }

    private fun parseNetwork(line: String, trusted: Boolean): NetworkRule? {
        if (line.startsWith("@@") || !youtubeNetworkPattern(line)) return null
        val dollar = line.indexOf('$')
        val pattern = if (dollar >= 0) line.substring(0, dollar) else line
        val options = if (dollar >= 0) splitUboArguments(line.substring(dollar + 1)) else emptyList()
        var badfilter = false
        var replace: String? = null
        for (option in options) {
            when {
                option == "badfilter" -> badfilter = true
                option.startsWith("replace=") -> if (trusted) replace = option.removePrefix("replace=") else return null
                option.startsWith("domain=") -> if (option.removePrefix("domain=").split('|').none { appliesToHost(it) }) return null
                option in NETWORK_OPTIONS -> Unit
                else -> return null // modificateur non géré : la règle est ignorée
            }
        }
        val key = pattern + "$" + options.filter { it != "badfilter" }.sorted().joinToString(",")
        val regex = patternToRegex(pattern)
        // La page peut appeler fetch avec une adresse relative (« /youtubei/v1/… ») : la
        // réécriture se repère au chemin seul, la page étant déjà celle de YouTube.
        val path = pattern.removePrefix("||").let { rest -> rest.indexOf('/').takeIf { it >= 0 }?.let { rest.substring(it) } }
        val replacement = replace?.let { parseReplace(it, path?.let(::patternToRegex) ?: regex, line) ?: return null }
        return NetworkRule(key, regex, badfilter, replacement)
    }

    private fun parseReplace(value: String, urlRegex: String, ruleText: String): Replacement? {
        // /motif/remplacement/drapeaux
        if (!value.startsWith("/")) return null
        val parts = mutableListOf<String>()
        val current = StringBuilder()
        var i = 1
        while (i < value.length) {
            val c = value[i]
            if (c == '\\' && i + 1 < value.length) {
                current.append(c).append(value[i + 1])
                i += 2
                continue
            }
            if (c == '/' && parts.size < 2) {
                parts += current.toString()
                current.clear()
            } else {
                current.append(c)
            }
            i++
        }
        if (parts.size != 2) return null
        val (pattern, replacement) = parts
        val flags = current.toString()
        val args = listOf("/$pattern/$flags", replacement, "/$urlRegex/")
        return Replacement(
            listOf(
                ScriptletCall("trusted-replace-fetch-response", args, ruleText),
                ScriptletCall("trusted-replace-xhr-response", args, ruleText),
            ),
        )
    }

    /** Motif d'adresse des listes (`||`, `^`, `*`, `|`) → expression régulière. */
    internal fun patternToRegex(pattern: String): String {
        val result = StringBuilder()
        var body = pattern
        when {
            body.startsWith("||") -> {
                result.append("^[a-z][a-z0-9+.-]*://(?:[^/?#]*\\.)?")
                body = body.substring(2)
            }
            body.startsWith("|") -> {
                result.append('^')
                body = body.substring(1)
            }
        }
        val anchoredEnd = body.endsWith("|")
        if (anchoredEnd) body = body.dropLast(1)
        for (c in body) {
            when (c) {
                '*' -> result.append(".*")
                '^' -> result.append("(?:[^\\w.%-]|$)")
                in "\\.+?()[]{}\$|/" -> result.append('\\').append(c)
                else -> result.append(c)
            }
        }
        if (anchoredEnd) result.append('$')
        return result.toString()
    }
}
