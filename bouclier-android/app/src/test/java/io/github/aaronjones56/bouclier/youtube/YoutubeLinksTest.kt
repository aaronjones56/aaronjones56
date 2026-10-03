package io.github.aaronjones56.bouclier.youtube

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class YoutubeLinksTest {

    @Test
    fun findsTheLinkInSharedText() {
        assertEquals(
            "https://youtu.be/dQw4w9WgXcQ?si=AbCdEf",
            YoutubeLinks.findUrl("Regarde ça : https://youtu.be/dQw4w9WgXcQ?si=AbCdEf !"),
        )
        assertEquals(
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            YoutubeLinks.findUrl("https://exemple.com/page puis https://www.youtube.com/watch?v=dQw4w9WgXcQ."),
        )
        assertNull(YoutubeLinks.findUrl("Aucun lien YouTube ici : https://exemple.com"))
    }

    @Test
    fun convertsVideoLinksToTheMobileSite() {
        val expected = "https://m.youtube.com/watch?v=dQw4w9WgXcQ"
        assertEquals(expected, YoutubeLinks.toMobileUrl("https://youtu.be/dQw4w9WgXcQ?si=AbCdEf"))
        assertEquals(expected, YoutubeLinks.toMobileUrl("https://www.youtube.com/watch?v=dQw4w9WgXcQ&feature=share"))
        assertEquals(expected, YoutubeLinks.toMobileUrl("https://m.youtube.com/watch?v=dQw4w9WgXcQ"))
        assertEquals(expected, YoutubeLinks.toMobileUrl("https://music.youtube.com/watch?v=dQw4w9WgXcQ"))
        assertEquals(expected, YoutubeLinks.toMobileUrl("https://www.youtube.com/live/dQw4w9WgXcQ?si=x"))
        assertEquals(expected, YoutubeLinks.toMobileUrl("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ"))
    }

    @Test
    fun keepsStartTimeAndPlaylist() {
        assertEquals(
            "https://m.youtube.com/watch?v=dQw4w9WgXcQ&t=90",
            YoutubeLinks.toMobileUrl("https://youtu.be/dQw4w9WgXcQ?t=90"),
        )
        assertEquals(
            "https://m.youtube.com/watch?v=dQw4w9WgXcQ&t=3723&list=PL1234abcd",
            YoutubeLinks.toMobileUrl("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1h2m3s&list=PL1234abcd&index=2"),
        )
        assertEquals(90, YoutubeLinks.startSeconds("1m30s"))
        assertEquals(45, YoutubeLinks.startSeconds("45s"))
        assertNull(YoutubeLinks.startSeconds("0"))
        assertNull(YoutubeLinks.startSeconds("abc"))
    }

    @Test
    fun convertsShortsAndOtherPages() {
        assertEquals("https://m.youtube.com/shorts/aBcDeFgHiJk", YoutubeLinks.toMobileUrl("https://youtube.com/shorts/aBcDeFgHiJk?si=x"))
        assertEquals("https://m.youtube.com/@Chaine", YoutubeLinks.toMobileUrl("https://www.youtube.com/@Chaine?si=x"))
        assertEquals("https://m.youtube.com/playlist?list=PL1234", YoutubeLinks.toMobileUrl("https://www.youtube.com/playlist?list=PL1234"))
        assertEquals("https://m.youtube.com/results?search_query=chat+mignon", YoutubeLinks.toMobileUrl("https://www.youtube.com/results?search_query=chat%20mignon"))
        assertEquals("https://m.youtube.com/", YoutubeLinks.toMobileUrl("https://www.youtube.com"))
    }

    @Test
    fun rejectsOtherSitesAndInvalidIds() {
        assertNull(YoutubeLinks.toMobileUrl("https://exemple.com/watch?v=dQw4w9WgXcQ"))
        assertNull(YoutubeLinks.toMobileUrl("https://youtube.com.exemple.com/watch?v=dQw4w9WgXcQ"))
        assertNull(YoutubeLinks.toMobileUrl("https://youtu.be/trop-court"))
        assertNull(YoutubeLinks.toMobileUrl("https://www.youtube.com/watch?v=<script>"))
        assertNull(YoutubeLinks.toMobileUrl("pas une adresse"))
    }
}
