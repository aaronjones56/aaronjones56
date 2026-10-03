package io.github.aaronjones56.bouclier.filter

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DomainMatcherTest {

    @Test
    fun hashedSetMatchesDomainAndSubdomains() {
        val set = HashedDomainSet.of(listOf("ads.example.com", "tracker.net"))
        assertTrue(set.matches("ads.example.com"))
        assertTrue(set.matches("cdn.ads.example.com"))
        assertTrue(set.matches("a.b.tracker.net"))
        assertFalse(set.matches("example.com"))
        assertFalse(set.matches("badads.example.com"))
        assertFalse(set.matches("tracker.net.evil.org"))
        assertFalse(set.matches(""))
        assertEquals(2, set.size)
    }

    @Test
    fun builderSortsAndRemovesDuplicates() {
        val builder = LongArrayBuilder(initialCapacity = 2)
        listOf(5L, -3L, 5L, 9L, -3L, 0L).forEach(builder::add)
        assertArrayEquals(longArrayOf(-3L, 0L, 5L, 9L), builder.toSortedUnique())
        assertArrayEquals(longArrayOf(1L, 2L, 3L), mergeHashes(listOf(longArrayOf(1L, 3L), longArrayOf(2L, 3L))))
    }

    @Test
    fun hashOfSuffixEqualsHashOfSubstring() {
        val domain = "a.b.example.com"
        assertEquals(DomainHash.of("example.com"), DomainHash.of(domain, domain.indexOf("example")))
    }

    @Test
    fun compiledListRoundTrips() {
        val list = CompiledList(longArrayOf(-7L, 1L, Long.MAX_VALUE), longArrayOf(42L))
        val decoded = CompiledList.decode(list.encode())!!
        assertArrayEquals(list.blocked, decoded.blocked)
        assertArrayEquals(list.exceptions, decoded.exceptions)
        assertNull(CompiledList.decode(byteArrayOf(1, 2, 3)))
        assertNull(CompiledList.decode(list.encode().copyOf(20)))
    }

    @Test
    fun appliesRulesInPriorityOrder() {
        val matcher = DomainMatcher(
            blocked = HashedDomainSet.of(listOf("ads.example.com", "tracker.net", "cdn.site.org")),
            exceptions = HashedDomainSet.of(listOf("ok.tracker.net")),
            userBlocked = setOf("annoying.com", "allowed-by-user.ads.example.com"),
            userAllowed = setOf("cdn.site.org", "allowed-by-user.ads.example.com"),
            usingBuiltinList = false,
        )
        assertEquals(Verdict.BLOCKED, matcher.verdict("ads.example.com"))
        assertEquals(Verdict.BLOCKED, matcher.verdict("x.tracker.net"))
        assertEquals(Verdict.ALLOWED, matcher.verdict("ok.tracker.net"))
        assertEquals(Verdict.ALLOWED, matcher.verdict("deeper.ok.tracker.net"))
        assertEquals(Verdict.ALLOWED_BY_USER, matcher.verdict("img.cdn.site.org"))
        assertEquals(Verdict.BLOCKED_BY_USER, matcher.verdict("www.annoying.com"))
        assertEquals(Verdict.ALLOWED_BY_USER, matcher.verdict("allowed-by-user.ads.example.com"))
        assertEquals(Verdict.ALLOWED, matcher.verdict("example.com"))
        assertEquals(Verdict.ALLOWED, matcher.verdict(""))
    }

    @Test
    fun userRulesCanBeReplacedWithoutTouchingLists() {
        val matcher = DomainMatcher(HashedDomainSet.of(listOf("ads.example.com")), HashedDomainSet.EMPTY, emptySet(), emptySet(), false)
        val updated = matcher.withUserRules(blocked = setOf("other.com"), allowed = setOf("ads.example.com"))
        assertEquals(Verdict.ALLOWED_BY_USER, updated.verdict("ads.example.com"))
        assertEquals(Verdict.BLOCKED_BY_USER, updated.verdict("other.com"))
        assertEquals(1, updated.blockedDomainCount)
    }

    @Test
    fun builtinListBlocksWellKnownAdDomains() {
        val matcher = DomainMatcher(BuiltinBlocklist.set, HashedDomainSet.EMPTY, emptySet(), emptySet(), true)
        assertEquals(Verdict.BLOCKED, matcher.verdict("securepubads.g.doubleclick.net"))
        assertEquals(Verdict.BLOCKED, matcher.verdict("pagead2.googlesyndication.com"))
        assertEquals(Verdict.ALLOWED, matcher.verdict("www.google.com"))
        assertEquals(Verdict.ALLOWED, matcher.verdict("www.youtube.com"))
    }
}
