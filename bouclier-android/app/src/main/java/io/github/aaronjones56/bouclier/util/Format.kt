package io.github.aaronjones56.bouclier.util

import android.text.format.DateUtils
import java.text.NumberFormat
import java.util.Locale
import kotlin.math.roundToLong

/** Mise en forme des nombres, tailles et dates, à la française. */
object Format {
    private val FRENCH = Locale.FRANCE

    /** 12345 → « 12 345 ». */
    fun count(value: Long): String = NumberFormat.getIntegerInstance(FRENCH).format(value)

    fun count(value: Int): String = count(value.toLong())

    /** Taille en octets → « 850 Ko », « 8 Mo », « 1,2 Go ». */
    fun bytes(bytes: Long): String {
        val kilo = 1024.0
        val mega = kilo * 1024
        val giga = mega * 1024
        return when {
            bytes <= 0 -> "0 Mo"
            bytes < mega -> "${count((bytes / kilo).roundToLong().coerceAtLeast(1))} Ko"
            bytes < 10 * mega -> decimal(bytes / mega) + " Mo"
            bytes < giga -> "${(bytes / mega).roundToLong()} Mo"
            else -> decimal(bytes / giga) + " Go"
        }
    }

    /** 0.0 à 1.0 → « 23 % ». */
    fun percent(ratio: Double): String = "${(ratio * 100).roundToLong()} %"

    /** « il y a 5 minutes », « hier »… selon la langue du téléphone. */
    fun relativeTime(time: Long): String =
        if (time <= 0) {
            "jamais"
        } else {
            DateUtils.getRelativeTimeSpanString(time, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS).toString()
        }

    /** Une décimale, sauf si elle est nulle : 8,0 → « 8 », 1,25 → « 1,3 ». */
    private fun decimal(value: Double): String {
        val text = String.format(FRENCH, "%.1f", value)
        return text.removeSuffix(",0")
    }
}
