package io.github.aaronjones56.bouclier.util

import org.junit.Assert.assertEquals
import org.junit.Test

class FormatTest {

    @Test
    fun groupsThousands() {
        val text = Format.count(1_234_567)
        assertEquals("1234567", text.filter { it.isDigit() })
        assertEquals(9, text.length) // deux séparateurs de milliers
    }

    @Test
    fun formatsSizesInFrench() {
        assertEquals("0 Mo", Format.bytes(0))
        assertEquals("1 Ko", Format.bytes(10))
        assertEquals("512 Ko", Format.bytes(512L * 1024))
        assertEquals("8 Mo", Format.bytes(8L * 1024 * 1024))
        assertEquals("1,3 Mo", Format.bytes(1_310_720)) // 1,25 Mo arrondi
        assertEquals("300 Mo", Format.bytes(300L * 1024 * 1024))
        assertEquals("1,5 Go", Format.bytes(1536L * 1024 * 1024))
    }

    @Test
    fun formatsPercentages() {
        assertEquals("36 %", Format.percent(0.364))
        assertEquals("0 %", Format.percent(0.0))
    }
}
