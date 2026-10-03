package io.github.aaronjones56.bouclier.vpn

import io.github.aaronjones56.bouclier.net.DnsMessages
import io.github.aaronjones56.bouclier.net.Packets
import io.github.aaronjones56.bouclier.net.TestPackets
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.SocketException
import kotlin.concurrent.thread

class UpstreamForwarderTest {

    private val loopback = InetAddress.getByName("127.0.0.1")
    private lateinit var server: DatagramSocket
    private var answerWithWrongId = false

    /** Faux serveur DNS : renvoie la requête marquée comme réponse. */
    @Before
    fun startServer() {
        server = DatagramSocket(InetSocketAddress(loopback, 0))
        thread(isDaemon = true) {
            val buffer = ByteArray(512)
            while (!server.isClosed) {
                val packet = DatagramPacket(buffer, buffer.size)
                try {
                    server.receive(packet)
                } catch (e: SocketException) {
                    break
                }
                val response = buffer.copyOf(packet.length)
                Packets.writeU16(response, 2, 0x8180)
                if (answerWithWrongId) Packets.writeU16(response, 0, Packets.readU16(response, 0) + 1)
                server.send(DatagramPacket(response, response.size, packet.socketAddress))
            }
        }
    }

    @After
    fun stopServer() = server.close()

    private fun forwarder(vararg servers: InetAddress) =
        UpstreamForwarder(protect = {}, servers = { servers.toList() }, port = server.localPort)

    @Test
    fun returnsTheServerResponse() {
        val query = TestPackets.dnsQuery("www.example.org", id = 0x4242)
        val response = forwarder(loopback).resolve(query)!!
        assertEquals(0x4242, Packets.readU16(response, 0))
        assertEquals(0x8180, Packets.readU16(response, 2))
        assertArrayEquals(query.copyOfRange(4, query.size), response.copyOfRange(4, response.size))
    }

    @Test
    fun fallsBackToTheNextServer() {
        // Personne n'écoute sur 127.0.0.2 : le premier essai échoue, le second répond.
        val query = TestPackets.dnsQuery("www.example.org", type = DnsMessages.TYPE_AAAA)
        val response = forwarder(InetAddress.getByName("127.0.0.2"), loopback).resolve(query)
        assertEquals(Packets.readU16(query, 0), Packets.readU16(response!!, 0))
    }

    @Test
    fun rejectsResponsesWithAnotherId() {
        answerWithWrongId = true
        assertNull(forwarder(loopback).resolve(TestPackets.dnsQuery("www.example.org")))
    }

    @Test
    fun ignoresTooShortQueries() {
        assertNull(forwarder(loopback).resolve(ByteArray(5)))
    }
}
