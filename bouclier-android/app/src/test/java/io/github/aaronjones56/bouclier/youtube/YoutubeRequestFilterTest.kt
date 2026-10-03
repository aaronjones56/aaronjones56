package io.github.aaronjones56.bouclier.youtube

import io.github.aaronjones56.bouclier.filter.DomainMatcher
import io.github.aaronjones56.bouclier.filter.HashedDomainSet
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class YoutubeRequestFilterTest {

    private val matcher = DomainMatcher(
        blocked = HashedDomainSet.of(listOf("doubleclick.net", "googlesyndication.com")),
        exceptions = HashedDomainSet.EMPTY,
        userBlocked = emptySet(),
        userAllowed = emptySet(),
        usingBuiltinList = false,
    )

    private fun blocked(url: String) = YoutubeRequestFilter.shouldBlock(url, matcher)

    @Test
    fun blocksAdNetworksFromTheFilterLists() {
        assertTrue(blocked("https://googleads.g.doubleclick.net/pagead/id"))
        assertTrue(blocked("https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js"))
    }

    @Test
    fun blocksYoutubeAdEndpoints() {
        assertTrue(blocked("https://m.youtube.com/api/stats/ads?ver=2&ns=yt"))
        assertTrue(blocked("https://www.youtube.com/pagead/viewthroughconversion/123"))
        assertTrue(blocked("https://www.youtube.com/ptracking?pltype=adhost"))
        assertTrue(blocked("https://m.youtube.com/youtubei/v1/player/ad_break?key=x"))
    }

    @Test
    fun letsVideosAndPagesThrough() {
        assertFalse(blocked("https://m.youtube.com/watch?v=dQw4w9WgXcQ"))
        assertFalse(blocked("https://m.youtube.com/youtubei/v1/player?key=x"))
        assertFalse(blocked("https://m.youtube.com/youtubei/v1/next?key=x"))
        assertFalse(blocked("https://rr3---sn-25ge7nzr.googlevideo.com/videoplayback?expire=1&id=o-AB"))
        assertFalse(blocked("https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"))
        assertFalse(blocked("https://www.youtube.com/s/player/abc/player_ias.vflset/fr_FR/base.js"))
        assertFalse(blocked("pas une adresse"))
    }
}
