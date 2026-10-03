package io.github.aaronjones56.bouclier.ui.components

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.BugReport
import androidx.compose.material.icons.outlined.Casino
import androidx.compose.material.icons.outlined.DesktopAccessDisabled
import androidx.compose.material.icons.outlined.Groups
import androidx.compose.material.icons.outlined.Link
import androidx.compose.material.icons.outlined.NoAdultContent
import androidx.compose.material.icons.outlined.Sync
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import io.github.aaronjones56.bouclier.filter.FilterCategory
import io.github.aaronjones56.bouclier.ui.theme.BouclierTheme

/** Icône représentant une catégorie de protection. */
val FilterCategory.icon: ImageVector
    get() = when (this) {
        FilterCategory.ADS -> Icons.Outlined.DesktopAccessDisabled
        FilterCategory.TRACKERS -> Icons.Outlined.VisibilityOff
        FilterCategory.SECURITY -> Icons.Outlined.BugReport
        FilterCategory.SOCIAL -> Icons.Outlined.Groups
        FilterCategory.ADULT -> Icons.Outlined.NoAdultContent
        FilterCategory.GAMBLING -> Icons.Outlined.Casino
        FilterCategory.CUSTOM -> Icons.Outlined.Link
    }

/** Grand interrupteur de l'écran d'accueil. */
@Composable
fun BigToggle(checked: Boolean, onCheckedChange: (Boolean) -> Unit, modifier: Modifier = Modifier) {
    val colors = BouclierTheme.colors
    val progress by animateFloatAsState(if (checked) 1f else 0f, label = "position")
    val trackColor by animateColorAsState(if (checked) colors.accent else colors.toggleOff, label = "piste")
    val trackWidth = 104.dp
    val trackHeight = 40.dp
    val knobSize = 68.dp
    val overhang = (knobSize - trackHeight) / 2
    Box(
        modifier
            .size(width = trackWidth + overhang * 2, height = knobSize)
            .semantics { contentDescription = "Interrupteur de protection" }
            .toggleable(
                value = checked,
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                role = Role.Switch,
                onValueChange = onCheckedChange,
            ),
    ) {
        Box(
            Modifier
                .align(Alignment.CenterStart)
                .padding(start = overhang)
                .size(width = trackWidth, height = trackHeight)
                .clip(CircleShape)
                .background(trackColor),
        )
        Box(
            Modifier
                .offset { IntOffset(((trackWidth - trackHeight) * progress).roundToPx(), 0) }
                .size(knobSize)
                .shadow(8.dp, CircleShape)
                .background(Color.White, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = if (checked) Icons.Rounded.Check else Icons.Rounded.Close,
                contentDescription = null,
                tint = if (checked) colors.accent else Color(0xFF9E9E9E),
                modifier = Modifier.size(36.dp),
            )
        }
    }
}

/** Bouton de mise à jour des listes ; l'icône tourne pendant le téléchargement. */
@Composable
fun SyncButton(updating: Boolean, onClick: () -> Unit) {
    val rotation = if (updating) {
        val transition = rememberInfiniteTransition(label = "sync")
        val angle by transition.animateFloat(
            initialValue = 0f,
            targetValue = -360f,
            animationSpec = infiniteRepeatable(tween(1000, easing = LinearEasing), RepeatMode.Restart),
            label = "angle",
        )
        angle
    } else {
        0f
    }
    IconButton(onClick = onClick, enabled = !updating) {
        Icon(
            Icons.Outlined.Sync,
            contentDescription = "Mettre à jour les listes de filtres",
            tint = BouclierTheme.colors.accent,
            modifier = Modifier.size(30.dp).rotate(rotation),
        )
    }
}

@Composable
fun ScreenHeader(title: String, subtitle: String? = null, action: (@Composable () -> Unit)? = null) {
    Row(
        Modifier
            .fillMaxWidth()
            .padding(start = 20.dp, end = 8.dp, top = 20.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
            if (subtitle != null) {
                Spacer(Modifier.height(4.dp))
                Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        action?.invoke()
    }
}

@Composable
fun SectionTitle(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        style = MaterialTheme.typography.titleSmall,
        fontWeight = FontWeight.SemiBold,
        color = BouclierTheme.colors.accent,
        modifier = modifier.padding(start = 20.dp, end = 20.dp, top = 24.dp, bottom = 4.dp),
    )
}

/** Interrupteur aux couleurs de Bouclier (curseur blanc), piloté par la ligne qui le contient. */
@Composable
fun BouclierSwitch(checked: Boolean, enabled: Boolean = true) {
    Switch(
        checked = checked,
        onCheckedChange = null,
        enabled = enabled,
        colors = SwitchDefaults.colors(
            checkedThumbColor = Color.White,
            checkedTrackColor = BouclierTheme.colors.accent,
            checkedBorderColor = BouclierTheme.colors.accent,
        ),
    )
}

/** Ligne de réglage avec interrupteur ; toute la ligne est cliquable. */
@Composable
fun SwitchRow(
    title: String,
    subtitle: String?,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    icon: ImageVector? = null,
    enabled: Boolean = true,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .toggleable(value = checked, enabled = enabled, role = Role.Switch, onValueChange = onCheckedChange)
            .padding(horizontal = 20.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) {
            Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.width(16.dp))
        }
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            if (subtitle != null) {
                Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        Spacer(Modifier.width(12.dp))
        BouclierSwitch(checked = checked, enabled = enabled)
    }
}

/** Ligne de réglage cliquable. */
@Composable
fun ClickRow(title: String, subtitle: String?, onClick: () -> Unit, icon: ImageVector? = null) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 20.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) {
            Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.width(16.dp))
        }
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            if (subtitle != null) {
                Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}
