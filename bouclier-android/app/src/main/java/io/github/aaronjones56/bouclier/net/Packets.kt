package io.github.aaronjones56.bouclier.net

import java.util.concurrent.atomic.AtomicInteger

/**
 * Lecture et construction des paquets IPv4 qui transitent par l'interface TUN.
 *
 * Seul le nécessaire est implémenté : les datagrammes UDP (requêtes DNS) et les
 * réinitialisations TCP (pour refuser tout de suite le DNS sur TCP ou TLS).
 * Aucune dépendance Android : le code est testé sur la JVM.
 */
object Packets {
    const val PROTOCOL_TCP = 6
    const val PROTOCOL_UDP = 17

    private const val IPV4_HEADER = 20
    private const val UDP_HEADER = 8
    private const val TCP_HEADER = 20

    private const val TCP_FIN = 0x01
    private const val TCP_SYN = 0x02
    private const val TCP_RST = 0x04
    private const val TCP_ACK = 0x10

    private val nextId = AtomicInteger()

    /** En-tête d'un paquet IPv4 reçu. */
    class Ipv4Header(
        val headerLength: Int,
        val totalLength: Int,
        val protocol: Int,
        val source: ByteArray,
        val destination: ByteArray,
    )

    /** En-tête UDP d'un paquet reçu ; les positions se rapportent au tampon d'origine. */
    class UdpHeader(
        val sourcePort: Int,
        val destinationPort: Int,
        val payloadOffset: Int,
        val payloadLength: Int,
    )

    /** Lit l'en-tête IPv4 de [buffer], ou `null` si ce n'est pas un paquet IPv4 complet et non fragmenté. */
    fun parseIpv4(buffer: ByteArray, length: Int): Ipv4Header? {
        if (length < IPV4_HEADER) return null
        val versionAndLength = buffer[0].toInt() and 0xFF
        if (versionAndLength ushr 4 != 4) return null
        val headerLength = (versionAndLength and 0x0F) * 4
        if (headerLength < IPV4_HEADER) return null
        val totalLength = readU16(buffer, 2)
        if (totalLength < headerLength || totalLength > length) return null
        // Un fragment (bit MF ou décalage non nul) n'est jamais une requête DNS entière.
        if (readU16(buffer, 6) and 0x3FFF != 0) return null
        return Ipv4Header(
            headerLength = headerLength,
            totalLength = totalLength,
            protocol = buffer[9].toInt() and 0xFF,
            source = buffer.copyOfRange(12, 16),
            destination = buffer.copyOfRange(16, 20),
        )
    }

    /** Lit l'en-tête UDP qui suit [ip], ou `null` si le segment est incomplet. */
    fun parseUdp(buffer: ByteArray, ip: Ipv4Header): UdpHeader? {
        if (ip.protocol != PROTOCOL_UDP) return null
        val offset = ip.headerLength
        if (ip.totalLength - offset < UDP_HEADER) return null
        val udpLength = readU16(buffer, offset + 4)
        if (udpLength < UDP_HEADER || offset + udpLength > ip.totalLength) return null
        return UdpHeader(
            sourcePort = readU16(buffer, offset),
            destinationPort = readU16(buffer, offset + 2),
            payloadOffset = offset + UDP_HEADER,
            payloadLength = udpLength - UDP_HEADER,
        )
    }

    /** Construit la réponse à un datagramme reçu : adresses et ports inversés, [payload] en données. */
    fun buildUdpReply(request: Ipv4Header, udp: UdpHeader, payload: ByteArray): ByteArray {
        val udpLength = UDP_HEADER + payload.size
        val packet = ByteArray(IPV4_HEADER + udpLength)
        writeIpv4Header(packet, PROTOCOL_UDP, source = request.destination, destination = request.source)
        writeU16(packet, IPV4_HEADER, udp.destinationPort)
        writeU16(packet, IPV4_HEADER + 2, udp.sourcePort)
        writeU16(packet, IPV4_HEADER + 4, udpLength)
        payload.copyInto(packet, IPV4_HEADER + UDP_HEADER)
        val checksum = transportChecksum(packet, PROTOCOL_UDP, udpLength)
        // En UDP, une somme nulle s'écrit 0xFFFF : la valeur 0 signifie « pas de somme ».
        writeU16(packet, IPV4_HEADER + 6, if (checksum == 0) 0xFFFF else checksum)
        return packet
    }

    /**
     * Construit le segment TCP RST qui refuse la connexion ouverte par [buffer], ou `null`
     * s'il ne faut pas répondre (le segment reçu est lui-même un RST, ou il est invalide).
     */
    fun buildTcpReset(buffer: ByteArray, ip: Ipv4Header): ByteArray? {
        if (ip.protocol != PROTOCOL_TCP) return null
        val offset = ip.headerLength
        if (ip.totalLength - offset < TCP_HEADER) return null
        val dataOffset = ((buffer[offset + 12].toInt() and 0xF0) ushr 4) * 4
        if (dataOffset < TCP_HEADER || offset + dataOffset > ip.totalLength) return null
        val flags = buffer[offset + 13].toInt() and 0xFF
        if (flags and TCP_RST != 0) return null

        var segmentLength = (ip.totalLength - offset - dataOffset).toLong()
        if (flags and TCP_SYN != 0) segmentLength++
        if (flags and TCP_FIN != 0) segmentLength++

        val packet = ByteArray(IPV4_HEADER + TCP_HEADER)
        writeIpv4Header(packet, PROTOCOL_TCP, source = ip.destination, destination = ip.source)
        writeU16(packet, IPV4_HEADER, readU16(buffer, offset + 2))
        writeU16(packet, IPV4_HEADER + 2, readU16(buffer, offset))
        // RFC 793 : le RST reprend le numéro d'acquittement reçu, sinon il acquitte le segment.
        if (flags and TCP_ACK != 0) {
            writeU32(packet, IPV4_HEADER + 4, readU32(buffer, offset + 8))
            packet[IPV4_HEADER + 13] = TCP_RST.toByte()
        } else {
            writeU32(packet, IPV4_HEADER + 8, (readU32(buffer, offset + 4) + segmentLength) and 0xFFFFFFFFL)
            packet[IPV4_HEADER + 13] = (TCP_RST or TCP_ACK).toByte()
        }
        packet[IPV4_HEADER + 12] = (5 shl 4).toByte() // en-tête de 5 mots, sans options
        writeU16(packet, IPV4_HEADER + 16, transportChecksum(packet, PROTOCOL_TCP, TCP_HEADER))
        return packet
    }

    private fun writeIpv4Header(packet: ByteArray, protocol: Int, source: ByteArray, destination: ByteArray) {
        packet[0] = 0x45 // IPv4, en-tête de 20 octets
        writeU16(packet, 2, packet.size)
        writeU16(packet, 4, nextId.getAndIncrement() and 0xFFFF)
        writeU16(packet, 6, 0x4000) // ne pas fragmenter
        packet[8] = 64 // TTL
        packet[9] = protocol.toByte()
        source.copyInto(packet, 12)
        destination.copyInto(packet, 16)
        writeU16(packet, 10, checksum(packet, 0, IPV4_HEADER, 0L))
    }

    /** Somme de contrôle UDP ou TCP (pseudo-en-tête IPv4 compris) du segment qui suit l'en-tête IP. */
    private fun transportChecksum(packet: ByteArray, protocol: Int, segmentLength: Int): Int {
        val pseudoHeader = sum16(packet, 12, 8, 0L) + protocol + segmentLength
        return checksum(packet, IPV4_HEADER, segmentLength, pseudoHeader)
    }

    /** Somme de contrôle Internet (RFC 1071) de [length] octets à partir de [offset]. */
    fun checksum(data: ByteArray, offset: Int, length: Int, initial: Long): Int {
        var sum = sum16(data, offset, length, initial)
        while (sum ushr 16 != 0L) sum = (sum and 0xFFFF) + (sum ushr 16)
        return (sum.inv() and 0xFFFF).toInt()
    }

    private fun sum16(data: ByteArray, offset: Int, length: Int, initial: Long): Long {
        var sum = initial
        var i = offset
        val end = offset + length
        while (i + 1 < end) {
            sum += readU16(data, i)
            i += 2
        }
        if (i < end) sum += (data[i].toInt() and 0xFF) shl 8
        return sum
    }

    fun readU16(data: ByteArray, offset: Int): Int =
        ((data[offset].toInt() and 0xFF) shl 8) or (data[offset + 1].toInt() and 0xFF)

    fun readU32(data: ByteArray, offset: Int): Long =
        (readU16(data, offset).toLong() shl 16) or readU16(data, offset + 2).toLong()

    fun writeU16(data: ByteArray, offset: Int, value: Int) {
        data[offset] = (value ushr 8).toByte()
        data[offset + 1] = value.toByte()
    }

    fun writeU32(data: ByteArray, offset: Int, value: Long) {
        writeU16(data, offset, (value ushr 16).toInt() and 0xFFFF)
        writeU16(data, offset + 2, value.toInt() and 0xFFFF)
    }
}
