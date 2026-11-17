package io.github.aaronjones56.bouclier.youtube.app

/** Rectangle à l'écran, en pixels. */
data class Box(val left: Int, val top: Int, val right: Int, val bottom: Int) {
    val isEmpty: Boolean get() = right <= left || bottom <= top
    val centerX: Int get() = (left + right) / 2
    val centerY: Int get() = (top + bottom) / 2

    operator fun contains(other: Box): Boolean =
        !isEmpty && !other.isEmpty && other.centerX in left..right && other.centerY in top..bottom
}

/**
 * Élément de l'écran de l'appli YouTube, tel que le voit le service d'accessibilité.
 * Interface séparée d'Android pour pouvoir tester la détection sans téléphone.
 */
interface ScreenNode {
    /** Identifiant complet de la vue (« com.google.android.youtube:id/skip_ad_button »), s'il existe. */
    val viewId: String?
    val text: String?
    val description: String?
    val isClickable: Boolean
    val isEnabled: Boolean
    val isVisible: Boolean
    val bounds: Box
    val parent: ScreenNode?
    val childCount: Int
    fun child(index: Int): ScreenNode?
}

/** Ce que l'écran montre : une pub en cours ? un bouton « Ignorer » à toucher ? où est le lecteur ? */
class AdScan(
    val adShowing: Boolean,
    /** Élément à toucher pour passer la pub (le bouton, ou son parent cliquable). */
    val skipTarget: ScreenNode?,
    /** Zone du bouton « Ignorer », pour le toucher par un geste si le clic direct échoue. */
    val skipBounds: Box?,
    /** Zone du lecteur vidéo, à masquer pendant la pub ; `null` : inconnue. */
    val playerArea: Box?,
    /** Indices qui ont fait conclure à une pub (rapport de détection). */
    val signals: List<String>,
    /** Identifiants et libellés liés aux pubs présents à l'écran (rapport de détection). */
    val clues: Set<String>,
)

/**
 * Reconnaît une publicité dans l'appli YouTube à partir de ce qu'elle affiche : identifiants des
 * vues publicitaires (compte à rebours, badge, bouton « Ignorer »), libellés comme
 * « Sponsorisé · 0:15 » ou « Ignorer ». Plusieurs indices sont combinés pour que les cartes
 * sponsorisées du fil ou un titre de vidéo ne soient jamais pris pour une pub en cours.
 */
object AppAdDetector {
    private const val MAX_NODES = 2500
    private const val MAX_DEPTH = 80
    private const val MAX_LABEL_LENGTH = 60

    /** Boutons « Ignorer » (identifiant de vue, sans le préfixe « paquet:id/ »). */
    private val SKIP_ID = Regex("""^(?:modern_)?skip_ad(?:_button)?(?:_text|_container)?$|^ad_skip\w*$""")

    /** Vues présentes seulement pendant une pub dans le lecteur. */
    private val AD_ID = Regex(
        """^(?:ad_progress_text|ad_countdown\w*|ad_badge|ad_title|ad_text|ad_attribution\w*|ad_cta_button\w*|""" +
            """ad_info_button|ad_overlay\w*|ad_player_overlay\w*|player_learn_more_button|visit_advertiser\w*|""" +
            """skip_ad\w*|modern_skip_ad\w*|ad_skip\w*)$""",
    )

    /** Lecteur vidéo, pour savoir quelle zone masquer. */
    private val PLAYER_ID = Regex("""^(?:watch_player|player_view|player_fragment_container|youtube_player_view|inline_player\w*|watch_while_player\w*)$""")

    /** Libellé exact d'un bouton « Ignorer ». */
    private val SKIP_LABEL = Regex(
        """^(?:ignorer(?: l'annonce| l’annonce| les annonces| la pub(?:licité)?)?|passer(?: l'annonce| l’annonce)?|skip(?: ads?| this ad)?)\s*[›>»▸▶]?$""",
        RegexOption.IGNORE_CASE,
    )

    /** Badge de pub du lecteur : « Sponsorisé · … », « Annonce · … », « Ad · … ». */
    private val AD_BADGE = Regex("""^(?:sponsoris[ée]|annonce|publicit[ée]|ads?|sponsored)\s*[·•]""", RegexOption.IGNORE_CASE)

    /** Compte à rebours ou rang de la pub (« 0:15 », « 1 sur 2 ») : absent des cartes du fil. */
    private val AD_PROGRESS = Regex("""\b\d{1,2}:\d{2}\b|\b\d+\s+(?:sur|of)\s+\d+\b""", RegexOption.IGNORE_CASE)

    /** Ce qui ressemble à une pub, pour le rapport (sans rien relever d'autre de l'écran). */
    private val CLUE = Regex("""ad_|_ad\b|skip|sponsor|annonce|publicit|ignorer|promo|advertiser""", RegexOption.IGNORE_CASE)

    fun scan(roots: List<ScreenNode>): AdScan {
        val adIds = mutableListOf<String>()
        val adLabels = mutableListOf<Pair<String, Box>>()
        val skipById = mutableListOf<ScreenNode>()
        val skipByLabel = mutableListOf<ScreenNode>()
        val clues = sortedSetOf<String>()
        var player: Box? = null
        var visited = 0

        fun visit(node: ScreenNode, depth: Int) {
            if (visited >= MAX_NODES || depth > MAX_DEPTH) return
            visited++
            // Ce qui n'est pas à l'écran (listes défilées…) ne compte pas, ni ses enfants.
            if (!node.isVisible) return
            val id = node.viewId?.substringAfter(":id/")
            val label = (node.text?.takeIf { it.isNotBlank() } ?: node.description)?.trim()
            if (id != null) {
                if (SKIP_ID.matches(id) && node.isEnabled) skipById += node
                if (AD_ID.matches(id)) adIds += id
                if (player == null && PLAYER_ID.matches(id) && !node.bounds.isEmpty) player = node.bounds
                if (CLUE.containsMatchIn(id)) clues += "id:$id"
            }
            if (label != null && label.length <= MAX_LABEL_LENGTH) {
                if (SKIP_LABEL.matches(label) && node.isEnabled) skipByLabel += node
                if (AD_BADGE.containsMatchIn(label) && AD_PROGRESS.containsMatchIn(label)) adLabels += label to node.bounds
                if (CLUE.containsMatchIn(label)) clues += "texte:$label"
            }
            for (index in 0 until node.childCount) {
                visit(node.child(index) ?: continue, depth + 1)
            }
        }
        roots.forEach { visit(it, 0) }

        val playerArea = player
        fun inPlayer(box: Box) = playerArea == null || box in playerArea

        val labelSignals = adLabels.filter { (_, box) -> inPlayer(box) }.map { "texte:${it.first}" }
        val idSignals = adIds.distinct().map { "id:$it" }
        val otherSignals = idSignals + labelSignals
        // Un simple bouton « Ignorer » ne suffit que s'il est dans le lecteur ou accompagné d'un autre indice.
        val skip = skipById.firstOrNull()
            ?: skipByLabel.firstOrNull { (playerArea != null && it.bounds in playerArea) || otherSignals.isNotEmpty() }
        val signals = otherSignals + listOfNotNull(skip?.let { "ignorer:${it.viewId?.substringAfter(":id/") ?: it.text ?: it.description}" })
        return AdScan(
            adShowing = signals.isNotEmpty(),
            skipTarget = skip?.let(::clickableTarget),
            skipBounds = skip?.bounds?.takeUnless { it.isEmpty },
            playerArea = playerArea,
            signals = signals,
            clues = clues,
        )
    }

    /** Le bouton lui-même s'il est cliquable, sinon le plus proche parent cliquable. */
    private fun clickableTarget(node: ScreenNode): ScreenNode? {
        var current: ScreenNode? = node
        repeat(6) {
            val candidate = current ?: return null
            if (candidate.isClickable && candidate.isEnabled) return candidate
            current = candidate.parent
        }
        return null
    }
}
