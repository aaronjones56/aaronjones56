package io.github.aaronjones56.bouclier.net

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DnsMessagesTest {

    @Test
    fun parsesQuestionInLowerCase() {
        val query = TestPackets.dnsQuery("Ads.Example.COM", type = DnsMessages.TYPE_AAAA)
        val question = DnsMessages.parseQuestion(query)!!
        assertEquals("ads.example.com", question.name)
        assertEquals(DnsMessages.TYPE_AAAA, question.type)
        assertEquals(DnsMessages.CLASS_IN, question.qclass)
        assertEquals(query.size, question.end)
    }

    @Test
    fun parsesRootQuery() {
        val question = DnsMessages.parseQuestion(TestPackets.dnsQuery(""))!!
        assertEquals("", question.name)
    }

    @Test
    fun rejectsResponsesAndMalformedMessages() {
        assertNull("réponse", DnsMessages.parseQuestion(TestPackets.dnsQuery("example.com", flags = 0x8180)))
        assertNull("opcode non standard", DnsMessages.parseQuestion(TestPackets.dnsQuery("example.com", flags = 0x2800)))
        val query = TestPackets.dnsQuery("example.com")
        assertNull("tronqué", DnsMessages.parseQuestion(query.copyOf(query.size - 3)))
        assertNull("en-tête seul", DnsMessages.parseQuestion(query.copyOf(12)))
        val twoQuestions = query.copyOf().also { Packets.writeU16(it, 4, 2) }
        assertNull("deux questions", DnsMessages.parseQuestion(twoQuestions))
        val pointer = query.copyOf().also { it[12] = 0xC0.toByte() }
        assertNull("pointeur de compression", DnsMessages.parseQuestion(pointer))
    }

    @Test
    fun blockedARecordAnswersNullAddress() {
        val query = TestPackets.dnsQuery("ads.example.com", id = 0xBEEF)
        val question = DnsMessages.parseQuestion(query)!!

        val response = DnsMessages.buildBlockedResponse(query, question, BlockResponse.NULL_IP)

        assertEquals(0xBEEF, Packets.readU16(response, 0))
        val flags = Packets.readU16(response, 2)
        assertEquals("QR", 0x8000, flags and 0x8000)
        assertEquals("RD recopié", 0x0100, flags and 0x0100)
        assertEquals("RA", 0x0080, flags and 0x0080)
        assertEquals("NOERROR", 0, flags and 0x000F)
        assertEquals(1, Packets.readU16(response, 4))
        assertEquals(1, Packets.readU16(response, 6))
        // La question est recopiée à l'identique.
        assertArrayEquals(query.copyOfRange(12, question.end), response.copyOfRange(12, question.end))
        var position = question.end
        assertEquals(0xC00C, Packets.readU16(response, position))
        assertEquals(DnsMessages.TYPE_A, Packets.readU16(response, position + 2))
        assertEquals(DnsMessages.CLASS_IN, Packets.readU16(response, position + 4))
        assertEquals(DnsMessages.BLOCKED_TTL.toLong(), Packets.readU32(response, position + 6))
        assertEquals(4, Packets.readU16(response, position + 10))
        position += 12
        assertArrayEquals(ByteArray(4), response.copyOfRange(position, position + 4))
        assertEquals(position + 4, response.size)
    }

    @Test
    fun blockedAaaaRecordAnswersUnspecifiedAddress() {
        val query = TestPackets.dnsQuery("ads.example.com", type = DnsMessages.TYPE_AAAA)
        val question = DnsMessages.parseQuestion(query)!!
        val response = DnsMessages.buildBlockedResponse(query, question, BlockResponse.NULL_IP)
        assertEquals(16, Packets.readU16(response, question.end + 10))
        assertEquals(question.end + 12 + 16, response.size)
    }

    @Test
    fun otherTypesGetAnEmptyAnswer() {
        val query = TestPackets.dnsQuery("ads.example.com", type = DnsMessages.TYPE_HTTPS)
        val question = DnsMessages.parseQuestion(query)!!
        val response = DnsMessages.buildBlockedResponse(query, question, BlockResponse.NULL_IP)
        assertEquals(0, Packets.readU16(response, 6))
        assertEquals(0, Packets.readU16(response, 2) and 0x000F)
        assertEquals(question.end, response.size)
    }

    @Test
    fun nxdomainModeAnswersNameError() {
        val query = TestPackets.dnsQuery("ads.example.com")
        val question = DnsMessages.parseQuestion(query)!!
        val response = DnsMessages.buildBlockedResponse(query, question, BlockResponse.NXDOMAIN)
        assertEquals(3, Packets.readU16(response, 2) and 0x000F)
        assertEquals(0, Packets.readU16(response, 6))
    }
}
