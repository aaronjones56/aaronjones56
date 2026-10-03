package io.github.aaronjones56.bouclier.ui

import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.View
import java.io.File

/** Enregistre le rendu de la vue dans app/build/screenshots (rendu natif de Robolectric). */
internal fun View.saveScreenshot(name: String) {
    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    draw(Canvas(bitmap))
    val directory = File("build/screenshots").apply { mkdirs() }
    File(directory, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
}
