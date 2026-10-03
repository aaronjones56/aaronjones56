package io.github.aaronjones56.bouclier.vpn

import io.github.aaronjones56.bouclier.filter.DomainMatcher
import io.github.aaronjones56.bouclier.filter.HashedDomainSet
import io.github.aaronjones56.bouclier.filter.Verdict
import io.github.aaronjones56.bouclier.net.BlockResponse
import io.github.aaronjones56.bouclier.net.Packets
import io.github.aaronjones56.bouclier.net.TestPackets
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class DnsPacketHandlerTest {

    private val queries = mutableListOf<Pair<String, Verdict>>()
    private var mode = BlockResponse.NULL_IP
    private val handler = DnsPacketHandler(
        dnsAddress = TestPackets.DNS_SERVER,
        matcher = {
            DomainMatcher(HashedDomainSet.of(listOf("ads.example.com")), HashedDomainSet.EMPTY, emptySet(), setOf("ok.ads.example.com"), false)
        },
        blockResponse = { mode },
        onQuery = { domain, _, verdict -> queries += domain to verdict },
    )

    private fun handle(packet: ByteArray) = handler.handle(packet.copyOf(packet.size + 64), packet.size)

    @Test
    fun answersBlockedDomainLocally() {
        val query = TestPackets.dnsQuery("banner.ads.example.com", id = 0x0A0B)
        val result = handle(TestPackets.ipv4Udp(query))

        assertTrue(result is DnsPacketHandler.Result.Reply)
        val reply = (result as DnsPacketHandler.Result.Reply).packet
        assertTrue(TestPackets.ipChecksumValid(reply))
        assertTrue(TestPackets.transportChecksumValid(reply, Packets.PROTOCOL_UDP))
        val ip = Packets.parseIpv4(reply, reply.size)!!
        assertArrayEquals(TestPackets.DNS_SERVER, ip.source)
        assertArrayEquals(TestPackets.CLIENT, ip.destination)
        val udp = Packets.parseUdp(reply, ip)!!
        assertEquals(53, udp.sourcePort)
        assertEquals(40000, udp.destinationPort)
        val dns = reply.copyOfRange(udp.payloadOffset, reply.size)
        assertEquals(0x0A0B, Packets.readU16(dns, 0))
        assertEquals(1, Packets.readU16(dns, 6)) // une réponse : 0.0.0.0
        assertArrayEquals(ByteArray(4), dns.copyOfRange(dns.size - 4, dns.size))
        assertEquals(listOf("banner.ads.example.com" to Verdict.BLOCKED), queries)
    }

    @Test
    fun usesConfiguredBlockResponse() {
        mode = BlockResponse.NXDOMAIN
        val result = handle(TestPackets.ipv4Udp(TestPackets.dnsQuery("ads.example.com")))
        val reply = (result as DnsPacketHandler.Result.Reply).packet
        assertEquals(3, Packets.readU16(reply, 28 + 2) and 0x000F)
    }

    @Test
    fun forwardsAllowedDomainsAndWrapsTheResponse() {
        val query = TestPackets.dnsQuery("www.example.org")
        val result = handle(TestPackets.ipv4Udp(query, sourcePort = 50123))

        assertTrue(result is DnsPacketHandler.Result.Forward)
        val forward = result as DnsPacketHandler.Result.Forward
        assertArrayEquals(query, forward.query)

        val upstreamResponse = query.copyOf().also { Packets.writeU16(it, 2, 0x8180) }
        val packet = forward.wrapResponse(upstreamResponse)
        assertTrue(TestPackets.ipChecksumValid(packet))
        assertTrue(TestPackets.transportChecksumValid(packet, Packets.PROTOCOL_UDP))
        assertEquals(50123, Packets.readU16(packet, 22))
        assertArrayEquals(upstreamResponse, packet.copyOfRange(28, packet.size))
        assertEquals(listOf("www.example.org" to Verdict.ALLOWED), queries)
    }

    @Test
    fun userAllowlistWins() {
        val result = handle(TestPackets.ipv4Udp(TestPackets.dnsQuery("ok.ads.example.com")))
        assertTrue(result is DnsPacketHandler.Result.Forward)
        assertEquals(listOf("ok.ads.example.com" to Verdict.ALLOWED_BY_USER), queries)
    }

    @Test
    fun forwardsUnusualQueriesWithoutFiltering() {
        val result = handle(TestPackets.ipv4Udp(TestPackets.dnsQuery("")))
        assertTrue(result is DnsPacketHandler.Result.Forward)
        assertTrue(queries.isEmpty())
    }

    @Test
    fun dropsTrafficNotAddressedToTheDnsServer() {
        val otherDestination = TestPackets.ipv4Udp(TestPackets.dnsQuery("ads.example.com"), destination = byteArrayOf(8, 8, 8, 8))
        assertSame(DnsPacketHandler.Result.Drop, handle(otherDestination))
        val otherPort = TestPackets.ipv4Udp(TestPackets.dnsQuery("ads.example.com"), destinationPort = 5353)
        assertSame(DnsPacketHandler.Result.Drop, handle(otherPort))
        assertSame(DnsPacketHandler.Result.Drop, handle(byteArrayOf(0x45, 0, 0)))
    }

    @Test
    fun refusesDnsOverTcpImmediately() {
        val result = handle(TestPackets.ipv4TcpSyn(sequence = 100))
        assertTrue(result is DnsPacketHandler.Result.Reply)
        val reset = (result as DnsPacketHandler.Result.Reply).packet
        assertEquals(0x14, reset[33].toInt())
        assertEquals(101L, Packets.readU32(reset, 28))
    }
}
