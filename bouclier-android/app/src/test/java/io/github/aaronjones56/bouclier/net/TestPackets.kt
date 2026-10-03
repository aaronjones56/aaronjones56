package io.github.aaronjones56.bouclier.net

import java.io.ByteArrayOutputStream

/** Fabrique de paquets pour les tests. */
object TestPackets {
    val CLIENT = byteArrayOf(10, 0, 0, 5)
    val DNS_SERVER = byteArrayOf(192.toByte(), 0, 2, 2)

    fun dnsQuery(name: String, type: Int = DnsMessages.TYPE_A, id: Int = 0x1234, flags: Int = 0x0100): ByteArray {
        val out = ByteArrayOutputStream()
        fun u16(value: Int) {
            out.write((value ushr 8) and 0xFF)
            out.write(value and 0xFF)
        }
        u16(id)
        u16(flags)
        u16(1) // QDCOUNT
        u16(0)
        u16(0)
        u16(0)
        if (name.isNotEmpty()) {
            for (label in name.split('.')) {
                out.write(label.length)
                out.write(label.toByteArray())
            }
        }
        out.write(0)
        u16(type)
        u16(DnsMessages.CLASS_IN)
        return out.toByteArray()
    }

    fun ipv4Udp(
        payload: ByteArray,
        source: ByteArray = CLIENT,
        destination: ByteArray = DNS_SERVER,
        sourcePort: Int = 40000,
        destinationPort: Int = 53,
    ): ByteArray {
        val packet = ByteArray(28 + payload.size)
        writeIpv4Header(packet, Packets.PROTOCOL_UDP, source, destination)
        Packets.writeU16(packet, 20, sourcePort)
        Packets.writeU16(packet, 22, destinationPort)
        Packets.writeU16(packet, 24, 8 + payload.size)
        payload.copyInto(packet, 28)
        return packet
    }

    fun ipv4TcpSyn(
        sequence: Long,
        source: ByteArray = CLIENT,
        destination: ByteArray = DNS_SERVER,
        sourcePort: Int = 41000,
        destinationPort: Int = 853,
    ): ByteArray {
        val packet = ByteArray(40)
        writeIpv4Header(packet, Packets.PROTOCOL_TCP, source, destination)
        Packets.writeU16(packet, 20, sourcePort)
        Packets.writeU16(packet, 22, destinationPort)
        Packets.writeU32(packet, 24, sequence)
        packet[32] = 0x50 // 5 mots
        packet[33] = 0x02 // SYN
        Packets.writeU16(packet, 34, 65535)
        return packet
    }

    private fun writeIpv4Header(packet: ByteArray, protocol: Int, source: ByteArray, destination: ByteArray) {
        packet[0] = 0x45
        Packets.writeU16(packet, 2, packet.size)
        packet[8] = 64
        packet[9] = protocol.toByte()
        source.copyInto(packet, 12)
        destination.copyInto(packet, 16)
        Packets.writeU16(packet, 10, Packets.checksum(packet, 0, 20, 0L))
    }

    /** Vrai si la somme de contrôle de l'en-tête IPv4 est correcte. */
    fun ipChecksumValid(packet: ByteArray): Boolean = Packets.checksum(packet, 0, 20, 0L) == 0

    /** Vrai si la somme de contrôle UDP ou TCP (pseudo-en-tête compris) est correcte. */
    fun transportChecksumValid(packet: ByteArray, protocol: Int): Boolean {
        val segmentLength = packet.size - 20
        var pseudoHeader = 0L
        for (i in 12 until 20 step 2) pseudoHeader += Packets.readU16(packet, i)
        pseudoHeader += protocol + segmentLength
        return Packets.checksum(packet, 20, segmentLength, pseudoHeader) == 0
    }
}
