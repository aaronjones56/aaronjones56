package io.github.aaronjones56.bouclier.youtube.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class AppAdDetectorTest {

    private class Node(
        override val viewId: String? = null,
        override val text: String? = null,
        override val description: String? = null,
        override val isClickable: Boolean = false,
        override val isEnabled: Boolean = true,
        override val isVisible: Boolean = true,
        override val bounds: Box = Box(0, 0, 1080, 2400),
        val children: List<Node> = emptyList(),
    ) : ScreenNode {
        override var parent: ScreenNode? = null
        override val childCount: Int get() = children.size
        override fun child(index: Int): ScreenNode = children[index]

        init {
            children.forEach { it.parent = this }
        }
    }

    private fun id(name: String) = "com.google.android.youtube:id/$name"

    private val playerBox = Box(0, 150, 1080, 760)
    private val belowPlayer = Box(0, 900, 1080, 1100)

    /** Page de lecture : lecteur en haut, titre, recommandations et carte sponsorisée en dessous. */
    private fun watchPage(vararg inPlayer: Node, below: List<Node> = emptyList()) = Node(
        children = listOf(
            Node(viewId = id("watch_player"), bounds = playerBox, children = inPlayer.toList()),
            Node(viewId = id("watch_list"), bounds = Box(0, 760, 1080, 2400), children = below),
        ),
    )

    @Test
    fun skipButtonFoundById() {
        val label = Node(viewId = id("modern_skip_ad_text"), text = "Ignorer", bounds = Box(800, 600, 1060, 700))
        val button = Node(viewId = id("skip_ad_button"), isClickable = true, bounds = Box(780, 590, 1070, 710), children = listOf(label))
        val scan = AppAdDetector.scan(listOf(watchPage(button)))
        assertTrue(scan.adShowing)
        assertSame(button, scan.skipTarget)
        assertEquals(playerBox, scan.playerArea)
    }

    @Test
    fun clicksTheClickableParentOfTheLabel() {
        val label = Node(text = "Ignorer l'annonce", bounds = Box(800, 600, 1060, 700))
        val container = Node(isClickable = true, bounds = Box(780, 590, 1070, 710), children = listOf(label))
        val scan = AppAdDetector.scan(listOf(watchPage(container)))
        assertTrue(scan.adShowing)
        assertSame(container, scan.skipTarget)
        assertEquals(label.bounds, scan.skipBounds)
    }

    @Test
    fun countdownBeforeTheSkipButtonIsAnAd() {
        val badge = Node(text = "Sponsorisé · 1 sur 2 · 0:12", bounds = Box(20, 680, 400, 740))
        val countdown = Node(viewId = id("skip_ad_button"), text = "5", isEnabled = false, bounds = Box(800, 600, 1060, 700))
        val scan = AppAdDetector.scan(listOf(watchPage(badge, countdown)))
        assertTrue(scan.adShowing)
        assertNull("bouton pas encore actif", scan.skipTarget)
    }

    @Test
    fun englishInterfaceToo() {
        val badge = Node(description = "Ad · 0:05", bounds = Box(20, 680, 400, 740))
        val skip = Node(description = "Skip ad", isClickable = true, bounds = Box(800, 600, 1060, 700))
        val scan = AppAdDetector.scan(listOf(watchPage(badge, skip)))
        assertTrue(scan.adShowing)
        assertSame(skip, scan.skipTarget)
    }

    @Test
    fun adOverlayIdsAloneMeanAnAd() {
        val scan = AppAdDetector.scan(listOf(watchPage(Node(viewId = id("ad_progress_text"), text = "0:14", bounds = Box(20, 680, 200, 740)))))
        assertTrue(scan.adShowing)
        assertEquals(listOf("id:ad_progress_text"), scan.signals)
    }

    @Test
    fun ordinaryVideoIsNotAnAd() {
        val scan = AppAdDetector.scan(
            listOf(
                watchPage(
                    Node(text = "1:23 / 12:45", bounds = Box(20, 680, 300, 740)),
                    Node(description = "Pause", isClickable = true, bounds = Box(490, 400, 590, 500)),
                    below = listOf(
                        Node(text = "Annonce officielle du concert 1 sur 3 · 20:00", bounds = belowPlayer),
                        Node(text = "Sponsorisé · exemple.fr", bounds = Box(0, 1100, 1080, 1300)),
                        Node(text = "Ignorer", isClickable = true, bounds = Box(0, 1300, 1080, 1400)),
                    ),
                ),
            ),
        )
        assertFalse(scan.adShowing)
        assertNull(scan.skipTarget)
    }

    @Test
    fun videoTitleShownOverThePlayerIsNotAnAd() {
        val scan = AppAdDetector.scan(listOf(watchPage(Node(text = "Annonce surprise : épisode 2 sur 5", bounds = Box(20, 160, 900, 220)))))
        assertFalse(scan.adShowing)
    }

    @Test
    fun hiddenElementsAreIgnored() {
        val hidden = Node(isVisible = false, children = listOf(Node(viewId = id("ad_progress_text"), text = "0:14")))
        assertFalse(AppAdDetector.scan(listOf(watchPage(hidden))).adShowing)
    }

    @Test
    fun withoutKnownPlayerASkipLabelNeedsAnotherClue() {
        val lonely = Node(children = listOf(Node(text = "Ignorer", isClickable = true)))
        assertFalse(AppAdDetector.scan(listOf(lonely)).adShowing)

        val withBadge = Node(
            children = listOf(
                Node(text = "Annonce · 0:09", bounds = Box(20, 680, 400, 740)),
                Node(text = "Ignorer", isClickable = true, bounds = Box(800, 600, 1060, 700)),
            ),
        )
        val scan = AppAdDetector.scan(listOf(withBadge))
        assertTrue(scan.adShowing)
        assertNull(scan.playerArea)
        assertTrue(scan.skipTarget != null)
    }

    @Test
    fun cluesOnlyMentionAdRelatedElements() {
        val scan = AppAdDetector.scan(
            listOf(
                watchPage(
                    Node(viewId = id("ad_badge"), text = "Sponsorisé · 0:15"),
                    Node(viewId = id("title"), text = "Recette des crêpes"),
                ),
            ),
        )
        assertEquals(setOf("id:ad_badge", "texte:Sponsorisé · 0:15"), scan.clues)
    }
}
