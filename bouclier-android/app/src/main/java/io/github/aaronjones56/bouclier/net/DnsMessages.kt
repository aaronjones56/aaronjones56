package io.github.aaronjones56.bouclier.net

/** Question d'une requête DNS ; [end] est la position qui suit la question dans le message. */
class DnsQuestion(val name: String, val type: Int, val qclass: Int, val end: Int)

/** Réponse renvoyée pour un domaine bloqué. */
enum class BlockResponse {
    /** 0.0.0.0 ou « :: » : l'application échoue tout de suite, sans chercher d'alternative. */
    NULL_IP,

    /** NXDOMAIN : le domaine est déclaré inexistant. */
    NXDOMAIN,
}

/** Lecture des requêtes DNS et fabrication des réponses de blocage (RFC 1035). */
object DnsMessages {
    const val TYPE_A = 1
    const val TYPE_AAAA = 28
    const val TYPE_HTTPS = 65
    const val CLASS_IN = 1

    /** Durée de mise en cache d'une réponse de blocage, en secondes. */
    const val BLOCKED_TTL = 60

    private const val HEADER_LENGTH = 12
    private const val MAX_NAME_LENGTH = 253
    private const val RCODE_NXDOMAIN = 3

    /** Lit l'unique question d'une requête standard, ou `null` si le message n'en est pas une. */
    fun parseQuestion(message: ByteArray): DnsQuestion? {
        if (message.size < HEADER_LENGTH) return null
        val flags = Packets.readU16(message, 2)
        if (flags and 0x8000 != 0) return null // c'est une réponse
        if ((flags ushr 11) and 0x0F != 0) return null // opcode autre que QUERY
        if (Packets.readU16(message, 4) != 1) return null // une question et une seule

        val name = StringBuilder()
        var position = HEADER_LENGTH
        while (true) {
            if (position >= message.size) return null
            val labelLength = message[position].toInt() and 0xFF
            position++
            if (labelLength == 0) break
            // Les pointeurs de compression n'ont rien à faire dans une question.
            if (labelLength and 0xC0 != 0) return null
            if (position + labelLength > message.size) return null
            if (name.isNotEmpty()) name.append('.')
            for (i in position until position + labelLength) {
                val c = message[i].toInt() and 0xFF
                name.append(if (c in 'A'.code..'Z'.code) (c + 32).toChar() else c.toChar())
            }
            if (name.length > MAX_NAME_LENGTH) return null
            position += labelLength
        }
        if (position + 4 > message.size) return null
        return DnsQuestion(
            name = name.toString(),
            type = Packets.readU16(message, position),
            qclass = Packets.readU16(message, position + 2),
            end = position + 4,
        )
    }

    /** Construit la réponse à [query] pour un domaine bloqué. */
    fun buildBlockedResponse(query: ByteArray, question: DnsQuestion, mode: BlockResponse): ByteArray {
        val addressLength = when {
            mode != BlockResponse.NULL_IP -> 0
            question.type == TYPE_A -> 4
            question.type == TYPE_AAAA -> 16
            else -> 0 // autres types : réponse vide (NODATA)
        }
        val answerLength = if (addressLength > 0) 12 + addressLength else 0
        val response = ByteArray(question.end + answerLength)
        query.copyInto(response, 0, 0, question.end)

        val queryFlags = Packets.readU16(query, 2)
        val rcode = if (mode == BlockResponse.NXDOMAIN) RCODE_NXDOMAIN else 0
        // QR = 1 (réponse), RD et CD recopiés de la requête, RA = 1.
        Packets.writeU16(response, 2, 0x8000 or (queryFlags and 0x0110) or 0x0080 or rcode)
        Packets.writeU16(response, 4, 1)
        Packets.writeU16(response, 6, if (addressLength > 0) 1 else 0)
        Packets.writeU16(response, 8, 0)
        Packets.writeU16(response, 10, 0)

        if (addressLength > 0) {
            var position = question.end
            Packets.writeU16(response, position, 0xC00C) // pointeur vers le nom de la question
            position += 2
            Packets.writeU16(response, position, question.type)
            position += 2
            Packets.writeU16(response, position, CLASS_IN)
            position += 2
            Packets.writeU32(response, position, BLOCKED_TTL.toLong())
            position += 4
            Packets.writeU16(response, position, addressLength)
            // L'adresse elle-même (0.0.0.0 ou ::) : octets déjà à zéro.
        }
        return response
    }

    /** Nom lisible d'un type d'enregistrement, pour le journal. */
    fun typeName(type: Int): String = when (type) {
        TYPE_A -> "A"
        TYPE_AAAA -> "AAAA"
        TYPE_HTTPS -> "HTTPS"
        5 -> "CNAME"
        12 -> "PTR"
        15 -> "MX"
        16 -> "TXT"
        33 -> "SRV"
        64 -> "SVCB"
        else -> "TYPE$type"
    }
}
