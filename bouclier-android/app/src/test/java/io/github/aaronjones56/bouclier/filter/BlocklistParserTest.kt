package io.github.aaronjones56.bouclier.filter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class BlocklistParserTest {

    private fun parse(text: String): Pair<List<String>, List<String>> {
        val blocked = mutableListOf<String>()
        val exceptions = mutableListOf<String>()
        BlocklistParser.parse(text) { domain, exception -> (if (exception) exceptions else blocked) += domain }
        return blocked to exceptions
    }

    @Test
    fun readsHostsFiles() {
        val (blocked, _) = parse(
            """
            # Title: StevenBlack/hosts
            127.0.0.1 localhost
            127.0.0.1 localhost.localdomain
            255.255.255.255 broadcasthost
            ::1 ip6-localhost
            0.0.0.0 0.0.0.0
            0.0.0.0 ads.example.com
            127.0.0.1	tracker.example.net   # pistage
            0.0.0.0 one.example.org two.example.org
            1.2.3.4 redirect.example.com
            """.trimIndent(),
        )
        assertEquals(listOf("ads.example.com", "tracker.example.net", "one.example.org", "two.example.org"), blocked)
    }

    @Test
    fun readsDomainLists() {
        val (blocked, _) = parse(
            """
            # HaGeZi
            plain.example.com
            *.wildcard.example.com
            UPPER.Example.COM.
            1.2.3.4
            localhost
            not_a_domain!
            """.trimIndent(),
        )
        assertEquals(listOf("plain.example.com", "wildcard.example.com", "upper.example.com"), blocked)
    }

    @Test
    fun readsAdblockDnsSyntax() {
        val (blocked, exceptions) = parse(
            """
            [Adblock Plus 2.0]
            ! Title: AdGuard DNS filter
            ||doubleclick.net^
            ||important.example.com^${'$'}important
            ||trailing.example.com^|
            @@||allowed.example.com^|
            @@||also-allowed.example.com^${'$'}important
            ||third-party.example.com^${'$'}third-party
            ||client.example.com^${'$'}client=192.168.1.1
            ||path.example.com/ads.js
            ||wild*.example.com^
            /^ad[0-9]+\.example\.com${'$'}/
            |https://anchored.example.com
            example.com##.banner
            example.com#@#.banner
            """.trimIndent(),
        )
        assertEquals(listOf("doubleclick.net", "important.example.com", "trailing.example.com"), blocked)
        assertEquals(listOf("allowed.example.com", "also-allowed.example.com"), exceptions)
    }

    @Test
    fun normalizesDomains() {
        assertEquals("example.com", BlocklistParser.normalizeDomain("  Example.COM. "))
        assertEquals("sub_domain.example.com", BlocklistParser.normalizeDomain("sub_domain.example.com"))
        assertNull(BlocklistParser.normalizeDomain("com"))
        assertNull(BlocklistParser.normalizeDomain(".example.com"))
        assertNull(BlocklistParser.normalizeDomain("-example.com"))
        assertNull(BlocklistParser.normalizeDomain("exa..mple.com"))
        assertNull(BlocklistParser.normalizeDomain("192.168.0.1"))
        assertNull(BlocklistParser.normalizeDomain("exämple.com"))
    }

    @Test
    fun extractsDomainFromUserInput() {
        assertEquals("ads.example.com", BlocklistParser.domainFromUserInput("https://ads.example.com/path?x=1"))
        assertEquals("example.com", BlocklistParser.domainFromUserInput("example.com:443"))
        assertEquals("example.com", BlocklistParser.domainFromUserInput("  *.Example.com "))
        assertNull(BlocklistParser.domainFromUserInput("pas un domaine"))
    }
}
