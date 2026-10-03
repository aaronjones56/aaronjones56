package io.github.aaronjones56.bouclier.vpn

import io.github.aaronjones56.bouclier.net.Packets
import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress

/**
 * Transmet une requête DNS autorisée au vrai serveur DNS et renvoie sa réponse.
 * Les serveurs sont essayés dans l'ordre ; chaque essai utilise une socket neuve,
 * « protégée » pour qu'elle ne repasse pas par le VPN.
 */
class UpstreamForwarder(
    private val protect: (DatagramSocket) -> Unit,
    private val servers: () -> List<InetAddress>,
    private val port: Int = DnsPacketHandler.DNS_PORT,
) {
    fun resolve(query: ByteArray): ByteArray? {
        if (query.size < 12) return null
        val queryId = Packets.readU16(query, 0)
        for ((attempt, server) in servers().take(MAX_ATTEMPTS).withIndex()) {
            try {
                DatagramSocket().use { socket ->
                    protect(socket)
                    socket.soTimeout = if (attempt == 0) FIRST_TIMEOUT_MS else RETRY_TIMEOUT_MS
                    socket.connect(InetSocketAddress(server, port))
                    socket.send(DatagramPacket(query, query.size))
                    val buffer = ByteArray(MAX_RESPONSE_SIZE)
                    val packet = DatagramPacket(buffer, buffer.size)
                    socket.receive(packet)
                    if (packet.length >= 12 && Packets.readU16(buffer, 0) == queryId) {
                        return buffer.copyOf(packet.length)
                    }
                }
            } catch (e: IOException) {
                // Délai dépassé ou réseau injoignable : on essaie le serveur suivant.
            }
        }
        return null
    }

    companion object {
        private const val MAX_ATTEMPTS = 3
        private const val FIRST_TIMEOUT_MS = 2500
        private const val RETRY_TIMEOUT_MS = 2000
        private const val MAX_RESPONSE_SIZE = 16 * 1024
    }
}
