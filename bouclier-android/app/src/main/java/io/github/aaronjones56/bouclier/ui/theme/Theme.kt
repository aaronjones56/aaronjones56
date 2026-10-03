package io.github.aaronjones56.bouclier.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color

/** Couleurs propres à Bouclier, en plus du thème Material. */
@Immutable
data class BouclierColors(
    val accent: Color,
    val inactiveIcon: Color,
    val card: Color,
    val warningContainer: Color,
    val warningBorder: Color,
    val warningIcon: Color,
    val danger: Color,
    val toggleOff: Color,
    val chartSurface: Color,
    val chartBlocked: Color,
    val chartAllowed: Color,
    val chartGrid: Color,
)

private val DarkExtraColors = BouclierColors(
    accent = Color(0xFF5CB97A),
    inactiveIcon = Color(0xFF7C7C7C),
    card = Color(0xFF383838),
    warningContainer = Color(0xFF4A3300),
    warningBorder = Color(0xFFE39A12),
    warningIcon = Color(0xFFF0A92A),
    danger = Color(0xFFFF7B72),
    toggleOff = Color(0xFF5A5A5A),
    chartSurface = Color(0xFF2A2A2A),
    // Graphique « mise en avant » : bloquées en vert, autorisées en gris (palette vérifiée).
    chartBlocked = Color(0xFF4AA96B),
    chartAllowed = Color(0xFF575757),
    chartGrid = Color(0xFF3A3A3A),
)

private val LightExtraColors = BouclierColors(
    accent = Color(0xFF2B8A4C),
    inactiveIcon = Color(0xFFA3A3A3),
    card = Color(0xFFFFFFFF),
    warningContainer = Color(0xFFFFF1D6),
    warningBorder = Color(0xFFE39A12),
    warningIcon = Color(0xFFB86E00),
    danger = Color(0xFFC62828),
    toggleOff = Color(0xFFBDBDBD),
    chartSurface = Color(0xFFFFFFFF),
    chartBlocked = Color(0xFF2B8A4C),
    chartAllowed = Color(0xFFC9C9C9),
    chartGrid = Color(0xFFE6E6E6),
)

private val DarkScheme = darkColorScheme(
    primary = Color(0xFF5CB97A),
    onPrimary = Color(0xFF06210F),
    primaryContainer = Color(0xFF23402D),
    onPrimaryContainer = Color(0xFFC8EBD3),
    secondary = Color(0xFF5CB97A),
    onSecondary = Color(0xFF06210F),
    secondaryContainer = Color(0xFF2F4A38),
    onSecondaryContainer = Color(0xFFC8EBD3),
    background = Color(0xFF1E1E1E),
    onBackground = Color(0xFFEDEDED),
    surface = Color(0xFF1E1E1E),
    onSurface = Color(0xFFEDEDED),
    surfaceVariant = Color(0xFF383838),
    onSurfaceVariant = Color(0xFFB5B5B5),
    surfaceContainerLowest = Color(0xFF191919),
    surfaceContainerLow = Color(0xFF242424),
    surfaceContainer = Color(0xFF2A2A2A),
    surfaceContainerHigh = Color(0xFF323232),
    surfaceContainerHighest = Color(0xFF3A3A3A),
    outline = Color(0xFF6A6A6A),
    outlineVariant = Color(0xFF3A3A3A),
    error = Color(0xFFFF7B72),
    onError = Color(0xFF3B0907),
)

private val LightScheme = lightColorScheme(
    primary = Color(0xFF2B8A4C),
    onPrimary = Color(0xFFFFFFFF),
    primaryContainer = Color(0xFFD9F0E0),
    onPrimaryContainer = Color(0xFF0B3A1C),
    secondary = Color(0xFF2B8A4C),
    onSecondary = Color(0xFFFFFFFF),
    secondaryContainer = Color(0xFFD9F0E0),
    onSecondaryContainer = Color(0xFF0B3A1C),
    background = Color(0xFFF5F5F4),
    onBackground = Color(0xFF1B1B1B),
    surface = Color(0xFFF5F5F4),
    onSurface = Color(0xFF1B1B1B),
    surfaceVariant = Color(0xFFE9E9E7),
    onSurfaceVariant = Color(0xFF55554F),
    surfaceContainerLowest = Color(0xFFFFFFFF),
    surfaceContainerLow = Color(0xFFFBFBFA),
    surfaceContainer = Color(0xFFFFFFFF),
    surfaceContainerHigh = Color(0xFFF0F0EE),
    surfaceContainerHighest = Color(0xFFE9E9E7),
    outline = Color(0xFF8A8A85),
    outlineVariant = Color(0xFFDADAD6),
    error = Color(0xFFC62828),
    onError = Color(0xFFFFFFFF),
)

private val LocalBouclierColors = staticCompositionLocalOf { DarkExtraColors }

@Composable
fun BouclierTheme(darkTheme: Boolean, content: @Composable () -> Unit) {
    CompositionLocalProvider(LocalBouclierColors provides if (darkTheme) DarkExtraColors else LightExtraColors) {
        MaterialTheme(colorScheme = if (darkTheme) DarkScheme else LightScheme, content = content)
    }
}

object BouclierTheme {
    val colors: BouclierColors
        @Composable get() = LocalBouclierColors.current
}
