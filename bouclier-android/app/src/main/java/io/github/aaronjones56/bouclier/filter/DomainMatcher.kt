package io.github.aaronjones56.bouclier.filter

/** Décision prise pour une requête DNS. */
enum class Verdict(val blocked: Boolean) {
    ALLOWED(false),
    ALLOWED_BY_USER(false),
    BLOCKED(true),
    BLOCKED_BY_USER(true),
}

/**
 * Décide si un domaine doit être bloqué. Ordre de priorité :
 * domaines autorisés par l'utilisateur, domaines bloqués par l'utilisateur,
 * exceptions des listes, puis listes de blocage.
 *
 * Immuable : un nouvel objet est publié à chaque changement de listes ou de règles,
 * ce qui permet de le lire sans verrou depuis le fil du VPN.
 */
class DomainMatcher(
    private val blocked: HashedDomainSet,
    private val exceptions: HashedDomainSet,
    val userBlocked: Set<String>,
    val userAllowed: Set<String>,
    /** Vrai tant qu'aucune liste n'a été téléchargée : la petite liste intégrée est utilisée. */
    val usingBuiltinList: Boolean,
) {
    val blockedDomainCount: Int get() = blocked.size

    fun verdict(domain: String): Verdict = when {
        domain.isEmpty() -> Verdict.ALLOWED
        matchesSuffix(userAllowed, domain) -> Verdict.ALLOWED_BY_USER
        matchesSuffix(userBlocked, domain) -> Verdict.BLOCKED_BY_USER
        exceptions.matches(domain) -> Verdict.ALLOWED
        blocked.matches(domain) -> Verdict.BLOCKED
        else -> Verdict.ALLOWED
    }

    fun withUserRules(blocked: Set<String>, allowed: Set<String>) =
        DomainMatcher(this.blocked, exceptions, blocked, allowed, usingBuiltinList)

    companion object {
        val EMPTY = DomainMatcher(HashedDomainSet.EMPTY, HashedDomainSet.EMPTY, emptySet(), emptySet(), false)

        /** Vrai si [domain] ou l'un de ses domaines parents appartient à [set]. */
        fun matchesSuffix(set: Set<String>, domain: String): Boolean {
            if (set.isEmpty()) return false
            var start = 0
            while (true) {
                if (set.contains(if (start == 0) domain else domain.substring(start))) return true
                val dot = domain.indexOf('.', start)
                if (dot < 0) return false
                start = dot + 1
            }
        }
    }
}
