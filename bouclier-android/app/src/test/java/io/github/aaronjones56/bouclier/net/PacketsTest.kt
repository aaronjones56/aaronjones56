package io.github.aaronjones56.bouclier.net

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PacketsTest {

    @Test
    fun parsesUdpDatagram() {
        val query = TestPackets.dnsQuery("example.com")
        val packet = TestPackets.ipv4Udp(query)

        val ip = Packets.parseIpv4(packet, packet.size)
        assertNotNull(ip)
        ip!!
        assertEquals(Packets.PROTOCOL_UDP, ip.protocol)
        assertArrayEquals(TestPackets.CLIENT, ip.source)
        assertArrayEquals(TestPackets.DNS_SERVER, ip.destination)

        val udp = Packets.parseUdp(packet, ip)!!
        assertEquals(40000, udp.sourcePort)
        assertEquals(53, udp.destinationPort)
        assertEquals(28, udp.payloadOffset)
        assertEquals(query.size, udp.payloadLength)
    }

    @Test
    fun ignoresTrailingBytesBeyondTotalLength() {
        val packet = TestPackets.ipv4Udp(TestPackets.dnsQuery("example.com"))
        val buffer = packet.copyOf(packet.size + 100)
        val ip = Packets.parseIpv4(buffer, buffer.size)!!
        assertEquals(packet.size, ip.totalLength)
    }

    @Test
    fun rejectsInvalidPackets() {
        val packet = TestPackets.ipv4Udp(TestPackets.dnsQuery("example.com"))
        assertNull("trop court", Packets.parseIpv4(packet, 10))
        assertNull("longueur annoncée supérieure à la longueur lue", Packets.parseIpv4(packet, packet.size - 1))

        val ipv6 = packet.copyOf().also { it[0] = 0x60 }
        assertNull("IPv6", Packets.parseIpv4(ipv6, ipv6.size))

        val fragment = packet.copyOf().also { Packets.writeU16(it, 6, 0x2000) } // bit MF
        assertNull("fragment", Packets.parseIpv4(fragment, fragment.size))

        val badUdpLength = packet.copyOf().also { Packets.writeU16(it, 24, 4000) }
        val ip = Packets.parseIpv4(badUdpLength, badUdpLength.size)!!
        assertNull("longueur UDP incohérente", Packets.parseUdp(badUdpLength, ip))
    }

    @Test
    fun buildsUdpReplyWithSwappedAddressesAndValidChecksums() {
        val packet = TestPackets.ipv4Udp(TestPackets.dnsQuery("example.com"))
        val ip = Packets.parseIpv4(packet, packet.size)!!
        val udp = Packets.parseUdp(packet, ip)!!
        val payload = byteArrayOf(1, 2, 3, 4, 5) // longueur impaire exprès

        val reply = Packets.buildUdpReply(ip, udp, payload)

        assertEquals(28 + payload.size, reply.size)
        assertTrue(TestPackets.ipChecksumValid(reply))
        assertTrue(TestPackets.transportChecksumValid(reply, Packets.PROTOCOL_UDP))
        val replyIp = Packets.parseIpv4(reply, reply.size)!!
        assertArrayEquals(TestPackets.DNS_SERVER, replyIp.source)
        assertArrayEquals(TestPackets.CLIENT, replyIp.destination)
        val replyUdp = Packets.parseUdp(reply, replyIp)!!
        assertEquals(53, replyUdp.sourcePort)
        assertEquals(40000, replyUdp.destinationPort)
        assertArrayEquals(payload, reply.copyOfRange(replyUdp.payloadOffset, reply.size))
    }

    @Test
    fun answersSynWithResetAcknowledgingIt() {
        val syn = TestPackets.ipv4TcpSyn(sequence = 0xFFFFFFFFL)
        val ip = Packets.parseIpv4(syn, syn.size)!!

        val reset = Packets.buildTcpReset(syn, ip)!!

        assertEquals(40, reset.size)
        assertTrue(TestPackets.ipChecksumValid(reset))
        assertTrue(TestPackets.transportChecksumValid(reset, Packets.PROTOCOL_TCP))
        assertEquals(853, Packets.readU16(reset, 20))
        assertEquals(41000, Packets.readU16(reset, 22))
        assertEquals(0L, Packets.readU32(reset, 24))
        // Le numéro d'acquittement couvre le SYN (avec retour à zéro après 2³² - 1).
        assertEquals(0L, Packets.readU32(reset, 28))
        assertEquals(0x14, reset[33].toInt()) // RST + ACK
    }

    @Test
    fun neverAnswersAReset() {
        val rst = TestPackets.ipv4TcpSyn(sequence = 1).also { it[33] = 0x04 }
        val ip = Packets.parseIpv4(rst, rst.size)!!
        assertNull(Packets.buildTcpReset(rst, ip))
    }
}
