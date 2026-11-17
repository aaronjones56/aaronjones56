package io.github.aaronjones56.bouclier.youtube

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class YoutubeRuleParserTest {

    private fun parse(text: String, trusted: Boolean = true, platform: Set<String> = emptySet()) =
        YoutubeRuleParser.parse(text.trimIndent(), trusted, platform)

    private fun YoutubeRules.calls() = scriptlets.map { listOf(it.name) + it.args }

    @Test
    fun readsAdguardScriptletsForTheMobileSite() {
        val rules = parse(
            """
            ! commentaire
            youtube.com#%#//scriptlet('set-constant', 'ytInitialPlayerResponse.adPlacements', 'undefined')
            m.youtube.com,youtubekids.com#%#//scriptlet("json-prune", "playerResponse.adPlacements adSlots")
            www.youtube.com#%#//scriptlet('set-constant', 'desktop', 'true')
            ~m.youtube.com,youtube.com#%#//scriptlet('set-constant', 'excluded', 'true')
            youtube.*#%#//scriptlet('set-constant', 'entity', 'true')
            #%#//scriptlet('set-constant', 'generic', 'true')
            example.com#%#//scriptlet('set-constant', 'other', 'true')
            """,
        )
        assertEquals(
            listOf(
                listOf("set-constant", "ytInitialPlayerResponse.adPlacements", "undefined"),
                listOf("json-prune", "playerResponse.adPlacements adSlots"),
                listOf("set-constant", "entity", "true"),
            ),
            rules.calls(),
        )
        assertEquals(
            "youtube.com#%#//scriptlet('set-constant', 'ytInitialPlayerResponse.adPlacements', 'undefined')",
            rules.scriptlets.first().ruleText,
        )
    }

    @Test
    fun keepsRegexArgumentsAndEscapedQuotes() {
        val rules = parse(
            """
            youtube.com#%#//scriptlet('json-prune-fetch-response', 'adPlacements', '', '/playlist\?list=|player\?|watch\?[tv]=/')
            youtube.com#%#//scriptlet('set-constant', 'a', 'l\'avion')
            youtube.com#%#//scriptlet('set-constant', 'broken
            """,
        )
        assertEquals(
            listOf(
                listOf("json-prune-fetch-response", "adPlacements", "", """/playlist\?list=|player\?|watch\?[tv]=/"""),
                listOf("set-constant", "a", "l'avion"),
            ),
            rules.calls(),
        )
    }

    @Test
    fun translatesUblockScriptlets() {
        val rules = parse(
            """
            m.youtube.com,www.youtube.com##+js(set, ytInitialPlayerResponse.playerAds, undefined)
            m.youtube.com##+js(json-prune-fetch-response, reelWatchSequenceResponse.entries.[-].command.reelWatchEndpoint.adClientParams.isAd, , propsToMatch, url:/reel_watch_sequence?)
            m.youtube.com##+js(json-prune, entries.[-].command.reelWatchEndpoint.adClientParams.isAd)
            m.youtube.com##+js(json-prune.js, a, b, propsToMatch, /x/)
            m.youtube.com##+js(json-edit-fetch-response, ..itemSectionRenderer.contents.*[?.adSlotRenderer], propsToMatch, /get_watch)
            m.youtube.com##+js(rmnt, script, adPlacements\, playerAds)
            m.youtube.com##+js(no-such-scriptlet, a)
            """,
        )
        assertEquals(
            listOf(
                listOf("set-constant", "ytInitialPlayerResponse.playerAds", "undefined"),
                listOf(
                    "json-prune-fetch-response",
                    "reelWatchSequenceResponse.entries.[-].command.reelWatchEndpoint.adClientParams.isAd",
                    "",
                    "url:/reel_watch_sequence?",
                ),
                listOf("json-prune", "entries.[-].command.reelWatchEndpoint.adClientParams.isAd"),
                listOf("remove-node-text", "script", "adPlacements, playerAds"),
            ),
            rules.calls(),
        )
    }

    @Test
    fun honoursExceptions() {
        val rules = parse(
            """
            youtube.com#%#//scriptlet('set-constant', 'a', 'true')
            youtube.com#%#//scriptlet('set-constant', 'b', 'true')
            m.youtube.com#@%#//scriptlet('set-constant', 'a', 'true')
            youtube.com##+js(set, c, true)
            youtube.com#@#+js(set, c, true)
            youtube.com##.ad
            youtube.com##.promo
            youtube.com#@#.promo
            youtube.com#%#window.x = 1;
            youtube.com#@%#window.x = 1;
            """,
        )
        assertEquals(listOf(listOf("set-constant", "b", "true")), rules.calls())
        assertEquals(listOf(".ad"), rules.hiddenSelectors)
        assertEquals(emptyList<String>(), rules.scripts)
    }

    @Test
    fun javascriptAndTrustedRulesOnlyFromTrustedLists() {
        val text = """
            m.youtube.com#%#(()=>{window.lact=1})();
            m.youtube.com#%#//scriptlet('trusted-replace-fetch-response', '"adPlacements"', '"no_ads"', '/get_watch/')
            m.youtube.com#%#//scriptlet('set-constant', 'a', 'true')
            ||youtube.com/youtubei/v1/get_watch?${'$'}xhr,1p,replace=/"adSlots"/"no_ads"/
        """
        val untrusted = parse(text, trusted = false)
        assertEquals(listOf(listOf("set-constant", "a", "true")), untrusted.calls())
        assertEquals(emptyList<String>(), untrusted.scripts)

        val trusted = parse(text, trusted = true)
        assertEquals(listOf("(()=>{window.lact=1})();"), trusted.scripts)
        assertEquals(4, trusted.scriptlets.size)
    }

    @Test
    fun turnsResponseReplacementsIntoScriptlets() {
        val rules = parse("""||youtube.com/youtubei/v1/get_watch?${'$'}xhr,1p,replace=/"adPlacements"/"no_ads"/""")
        val path = """/\/youtubei\/v1\/get_watch\?/"""
        assertEquals(
            listOf(
                listOf("trusted-replace-fetch-response", "/\"adPlacements\"/", "\"no_ads\"", path),
                listOf("trusted-replace-xhr-response", "/\"adPlacements\"/", "\"no_ads\"", path),
            ),
            rules.calls(),
        )
        assertEquals(emptyList<String>(), rules.blockedUrls)
    }

    @Test
    fun readsNetworkRules() {
        val rules = parse(
            """
            ||youtube.com/pagead/
            ||youtube.com/api/stats/qoe?*adformat=${'$'}xhr
            ||youtube.com/get_video_info?${'$'}~third-party
            ||youtube.com/get_video_info?${'$'}~third-party,badfilter
            ||youtube.com/embed/*${'$'}domain=1shortlink.com
            ||youtube.com/get_video${'$'}media,redirect=noopmp4-1s
            @@||youtube.com/my_video_ad${'$'}document
            ||example.com/youtube/ads
            ||youtube.com/ptracking^${'$'}domain=m.youtube.com|www.youtube.com
            """,
        )
        val blocked = rules.blockedUrls.map { Regex(it) }
        fun blocks(url: String) = blocked.any { it.containsMatchIn(url) }
        assertEquals(3, blocked.size)
        assertTrue(blocks("https://www.youtube.com/pagead/viewthroughconversion/1"))
        assertTrue(blocks("https://m.youtube.com/api/stats/qoe?event=1&adformat=15_2"))
        assertTrue(blocks("https://m.youtube.com/ptracking?pltype=adhost"))
        assertFalse(blocks("https://m.youtube.com/ptrackingx"))
        assertFalse(blocks("https://notyoutube.com/pagead/"))
        assertFalse(blocks("https://m.youtube.com/get_video_info?video_id=x"))
        assertFalse(blocks("https://m.youtube.com/embed/abc"))
        assertFalse(blocks("https://m.youtube.com/api/stats/qoe?event=1"))
    }

    @Test
    fun keepsOnlySelectorsTheBrowserUnderstands() {
        val rules = parse(
            """
            m.youtube.com##ytm-rich-item-renderer > ad-slot-renderer
            youtube.com##ytd-rich-item-renderer:has(> #content > ytd-ad-slot-renderer)
            youtube.com##.ytlr-item:has-text(Ad)
            youtube.com#?#div > ytd-display-ad-renderer:upward(2)
            youtube.com##^script:has-text(adPlacements)
            youtube.com#${'$'}#body { overflow: auto !important; }
            """,
        )
        assertEquals(
            listOf("ytm-rich-item-renderer > ad-slot-renderer", "ytd-rich-item-renderer:has(> #content > ytd-ad-slot-renderer)"),
            rules.hiddenSelectors,
        )
    }

    @Test
    fun resolvesConditionalBlocks() {
        val text = """
            !#if env_mobile
            youtube.com##.mobile
            !#else
            youtube.com##.desktop
            !#endif
            !#if (env_firefox || env_chromium) && !adguard
            youtube.com##.chromium
            !#if env_mv3
            youtube.com##.mv3
            !#endif
            !#endif
            !#if adguard_ext_chromium
            youtube.com##.adguard
            !#endif
            !#if ((broken
            youtube.com##.broken
            !#endif
            youtube.com##.always
        """
        assertEquals(
            listOf(".mobile", ".chromium", ".always"),
            parse(text, platform = YoutubeRuleParser.UBO_PLATFORM).hiddenSelectors,
        )
        assertEquals(
            listOf(".desktop", ".adguard", ".always"),
            parse(text, platform = YoutubeRuleParser.ADGUARD_PLATFORM).hiddenSelectors,
        )
    }

    @Test
    fun extractsTheLinesAboutYoutube() {
        val list = """
            ! Title: liste
            ##.generic-ad
            example.com##.ad
            youtube.com##.ad
            youtube.com##.ad
            !#if !env_mobile
            youtube.com##.desktop-only
            !#endif
            ||youtube.com/pagead/
            ||example.com/youtube.js
            @@||youtube.com/my_video_ad${'$'}document
            m.youtube.com#%#//scriptlet('set-constant', 'a', 'true')
        """.trimIndent()
        assertEquals(
            listOf(
                "youtube.com##.ad",
                "||youtube.com/pagead/",
                "@@||youtube.com/my_video_ad\$document",
                "m.youtube.com#%#//scriptlet('set-constant', 'a', 'true')",
            ),
            YoutubeRuleParser.relevantLines(list, YoutubeRuleParser.UBO_PLATFORM),
        )
    }

    @Test
    fun convertsAddressPatterns() {
        val regex = Regex(YoutubeRuleParser.patternToRegex("||youtube.com/api/stats/ads^"))
        assertTrue(regex.containsMatchIn("https://m.youtube.com/api/stats/ads?ver=2"))
        assertTrue(regex.containsMatchIn("https://youtube.com/api/stats/ads"))
        assertFalse(regex.containsMatchIn("https://m.youtube.com/api/stats/adsx"))
        assertFalse(regex.containsMatchIn("https://evil.com/?u=https://youtube.com.evil.com/api/stats/ads"))
    }

    @Test
    fun bundledRulesAreUsable() {
        val adguard = YoutubeRuleParser.parse(
            File("src/main/assets/youtube/default-rules-adguard.txt").readText(),
            trusted = true,
            platform = YoutubeRuleParser.ADGUARD_PLATFORM,
        )
        val ublock = YoutubeRuleParser.parse(
            File("src/main/assets/youtube/default-rules-ubo.txt").readText(),
            trusted = true,
            platform = YoutubeRuleParser.UBO_PLATFORM,
        )
        val names = (adguard + ublock).scriptlets.map { it.name }.toSet()
        assertTrue(names.containsAll(listOf("set-constant", "json-prune", "json-prune-fetch-response", "trusted-replace-fetch-response")))
        assertEquals(1, adguard.scripts.size)
        assertTrue(adguard.hiddenSelectors.contains("ytm-rich-item-renderer > ad-slot-renderer"))
        assertTrue(adguard.scriptlets.size >= 10)
        assertTrue(ublock.scriptlets.size >= 8)
    }
}
