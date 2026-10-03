package io.github.aaronjones56.bouclier.vpn

import io.github.aaronjones56.bouclier.filter.DomainMatcher
import io.github.aaronjones56.bouclier.filter.Verdict
import io.github.aaronjones56.bouclier.net.BlockResponse
import io.github.aaronjones56.bouclier.net.DnsMessages
import io.github.aaronjones56.bouclier.net.Packets

/**
 * Traite un paquet lu sur l'interface TUN. Seul le trafic adressé au serveur DNS
 * virtuel arrive ici : les requêtes vers un domaine bloqué reçoivent aussitôt une
 * réponse locale, les autres sont transmises au vrai serveur DNS.
 *
 * Aucune dépendance Android : testé sur la JVM.
 */
class DnsPacketHandler(
    private val dnsAddress: ByteArray,
    private val matcher: () -> DomainMatcher,
    private val blockResponse: () -> BlockResponse,
    private val onQuery: (domain: String, type: Int, verdict: Verdict) -> Unit,
) {
    sealed interface Result {
        /** Paquet ignoré. */
        data object Drop : Result

        /** Paquet de réponse à écrire tel quel sur l'interface TUN. */
        class Reply(val packet: ByteArray) : Result

        /** Requête à transmettre au serveur DNS ; [wrapResponse] emballe sa réponse en paquet IP. */
        class Forward(val query: ByteArray, val wrapResponse: (ByteArray) -> ByteArray) : Result
    }

    fun handle(buffer: ByteArray, length: Int): Result {
        val ip = Packets.parseIpv4(buffer, length) ?: return Result.Drop
        if (!ip.destination.contentEquals(dnsAddress)) return Result.Drop
        return when (ip.protocol) {
            Packets.PROTOCOL_UDP -> handleUdp(buffer, ip)
            // DNS sur TCP ou TLS (port 853, « DNS privé » automatique) : refus immédiat,
            // le système se rabat alors sur le DNS classique, que l'on filtre.
            Packets.PROTOCOL_TCP -> Packets.buildTcpReset(buffer, ip)?.let { Result.Reply(it) } ?: Result.Drop
            else -> Result.Drop
        }
    }

    private fun handleUdp(buffer: ByteArray, ip: Packets.Ipv4Header): Result {
        val udp = Packets.parseUdp(buffer, ip) ?: return Result.Drop
        if (udp.destinationPort != DNS_PORT || udp.payloadLength == 0) return Result.Drop
        val query = buffer.copyOfRange(udp.payloadOffset, udp.payloadOffset + udp.payloadLength)
        val wrap = { response: ByteArray -> Packets.buildUdpReply(ip, udp, response) }

        val question = DnsMessages.parseQuestion(query)
        // Requêtes inhabituelles (plusieurs questions, classe autre que IN…) : transmises sans filtrage.
        if (question == null || question.qclass != DnsMessages.CLASS_IN || question.name.isEmpty()) {
            return Result.Forward(query, wrap)
        }
        val verdict = matcher().verdict(question.name)
        onQuery(question.name, question.type, verdict)
        if (!verdict.blocked) return Result.Forward(query, wrap)
        return Result.Reply(wrap(DnsMessages.buildBlockedResponse(query, question, blockResponse())))
    }

    companion object {
        const val DNS_PORT = 53
    }
}
