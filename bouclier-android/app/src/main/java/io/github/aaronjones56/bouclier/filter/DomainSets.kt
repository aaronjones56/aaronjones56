package io.github.aaronjones56.bouclier.filter

import java.nio.ByteBuffer

/**
 * Empreinte 64 bits d'un nom de domaine (FNV-1a suivi du finaliseur de MurmurHash3).
 *
 * Les listes sont stockées sous forme d'empreintes triées : quelques mégaoctets de
 * mémoire pour plusieurs centaines de milliers de domaines, et une recherche
 * dichotomique très rapide. Le risque de collision est négligeable (~10⁻¹³ par requête).
 */
object DomainHash {
    private const val FNV_OFFSET = -0x340d631b7bdddcdbL // 0xcbf29ce484222325
    private const val FNV_PRIME = 0x100000001b3L

    /** Empreinte de la fin de [domain] à partir de la position [start]. */
    fun of(domain: String, start: Int = 0): Long {
        var hash = FNV_OFFSET
        for (i in start until domain.length) {
            hash = hash xor domain[i].code.toLong()
            hash *= FNV_PRIME
        }
        hash = hash xor (hash ushr 33)
        hash *= -0xae502812aa7333L // 0xff51afd7ed558ccd
        hash = hash xor (hash ushr 33)
        hash *= -0x3b314601e57a13adL // 0xc4ceb9fe1a85ec53
        return hash xor (hash ushr 33)
    }
}

/** Ensemble de domaines représenté par leurs empreintes triées et sans doublon. */
class HashedDomainSet(private val hashes: LongArray) {
    val size: Int get() = hashes.size

    /** Vrai si [domain] ou l'un de ses domaines parents appartient à l'ensemble. */
    fun matches(domain: String): Boolean {
        if (hashes.isEmpty() || domain.isEmpty()) return false
        var start = 0
        while (true) {
            if (hashes.binarySearch(DomainHash.of(domain, start)) >= 0) return true
            val dot = domain.indexOf('.', start)
            if (dot < 0) return false
            start = dot + 1
        }
    }

    companion object {
        val EMPTY = HashedDomainSet(LongArray(0))

        fun of(domains: Iterable<String>): HashedDomainSet {
            val builder = LongArrayBuilder()
            for (domain in domains) builder.add(DomainHash.of(domain))
            return HashedDomainSet(builder.toSortedUnique())
        }
    }
}

/** Tableau de `long` extensible, sans allocation par élément. */
class LongArrayBuilder(initialCapacity: Int = 1024) {
    private var data = LongArray(initialCapacity.coerceAtLeast(16))
    var size = 0
        private set

    fun add(value: Long) {
        if (size == data.size) data = data.copyOf(size * 2)
        data[size++] = value
    }

    fun addAll(values: LongArray) {
        if (size + values.size > data.size) data = data.copyOf(maxOf(size + values.size, size * 2))
        values.copyInto(data, size)
        size += values.size
    }

    /** Copie triée et dédoublonnée du contenu. */
    fun toSortedUnique(): LongArray {
        val sorted = data.copyOf(size)
        sorted.sort()
        var unique = 0
        for (value in sorted) {
            if (unique == 0 || sorted[unique - 1] != value) sorted[unique++] = value
        }
        return if (unique == sorted.size) sorted else sorted.copyOf(unique)
    }
}

/** Fusionne des tableaux d'empreintes en un seul tableau trié et sans doublon. */
fun mergeHashes(arrays: List<LongArray>): LongArray {
    if (arrays.isEmpty()) return LongArray(0)
    if (arrays.size == 1) return arrays[0]
    val builder = LongArrayBuilder(arrays.sumOf { it.size })
    for (array in arrays) builder.addAll(array)
    return builder.toSortedUnique()
}

/** Liste compilée : empreintes des domaines bloqués et des exceptions (« @@||domaine^ »). */
class CompiledList(val blocked: LongArray, val exceptions: LongArray) {

    fun encode(): ByteArray {
        val buffer = ByteBuffer.allocate(HEADER_SIZE + 8 * (blocked.size + exceptions.size))
        buffer.putInt(MAGIC).putInt(blocked.size).putInt(exceptions.size)
        val longs = buffer.asLongBuffer()
        longs.put(blocked)
        longs.put(exceptions)
        return buffer.array()
    }

    companion object {
        private const val MAGIC = 0x42434C31 // « BCL1 »
        private const val HEADER_SIZE = 12

        /** Relit une liste écrite par [encode], ou `null` si le contenu est invalide. */
        fun decode(bytes: ByteArray): CompiledList? {
            if (bytes.size < HEADER_SIZE) return null
            val buffer = ByteBuffer.wrap(bytes)
            if (buffer.int != MAGIC) return null
            val blockedCount = buffer.int
            val exceptionCount = buffer.int
            if (blockedCount < 0 || exceptionCount < 0) return null
            if (HEADER_SIZE + 8L * (blockedCount.toLong() + exceptionCount) != bytes.size.toLong()) return null
            val longs = buffer.asLongBuffer()
            val blocked = LongArray(blockedCount).also { longs.get(it) }
            val exceptions = LongArray(exceptionCount).also { longs.get(it) }
            return CompiledList(blocked, exceptions)
        }
    }
}
