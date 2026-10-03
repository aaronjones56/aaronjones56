package io.github.aaronjones56.bouclier.ui

import android.content.ClipData
import android.content.ClipboardManager
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Block
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.aaronjones56.bouclier.filter.FilterRepository
import io.github.aaronjones56.bouclier.filter.UserRules
import io.github.aaronjones56.bouclier.filter.Verdict
import io.github.aaronjones56.bouclier.net.DnsMessages
import io.github.aaronjones56.bouclier.stats.QueryLogEntry
import io.github.aaronjones56.bouclier.stats.StatsRepository
import io.github.aaronjones56.bouclier.stats.StatsSnapshot
import io.github.aaronjones56.bouclier.ui.components.ScreenHeader
import io.github.aaronjones56.bouclier.ui.components.SectionTitle
import io.github.aaronjones56.bouclier.ui.theme.BouclierTheme
import io.github.aaronjones56.bouclier.util.Format
import java.text.SimpleDateFormat
import java.time.LocalTime
import java.util.Date
import java.util.Locale
import kotlin.math.min

private enum class LogFilter(val title: String) { ALL("Toutes"), BLOCKED("Bloquées"), ALLOWED("Autorisées") }

@Composable
fun StatsScreen(onMessage: (String) -> Unit) {
    val stats by remember { StatsRepository.snapshots(1000) }
        .collectAsStateWithLifecycle(initialValue = remember { StatsRepository.snapshot() })
    val rules by FilterRepository.userRules.collectAsStateWithLifecycle()
    var logFilter by rememberSaveable { mutableStateOf(LogFilter.ALL) }
    var search by rememberSaveable { mutableStateOf("") }
    var showHourlyTable by rememberSaveable { mutableStateOf(false) }
    var selectedDomain by rememberSaveable { mutableStateOf<String?>(null) }
    var confirmReset by rememberSaveable { mutableStateOf(false) }
    val timeFormat = remember { SimpleDateFormat("HH:mm:ss", Locale.FRANCE) }

    val log = stats.recent.filter { entry ->
        when (logFilter) {
            LogFilter.ALL -> true
            LogFilter.BLOCKED -> entry.verdict.blocked
            LogFilter.ALLOWED -> !entry.verdict.blocked
        } && (search.isBlank() || entry.domain.contains(search.trim(), ignoreCase = true))
    }

    LazyColumn(Modifier.fillMaxSize()) {
        item { ScreenHeader(title = "Statistiques", subtitle = "Aujourd'hui, depuis minuit") }
        item { KpiTiles(stats) }
        item {
            Spacer(Modifier.height(12.dp))
            HourlyChart(stats)
        }
        item {
            TextButton(
                onClick = { showHourlyTable = !showHourlyTable },
                modifier = Modifier.padding(horizontal = 12.dp),
            ) { Text(if (showHourlyTable) "Masquer le détail heure par heure" else "Voir le détail heure par heure") }
        }
        if (showHourlyTable) {
            item { HourlyTable(stats) }
        }
        item {
            Text(
                "Depuis l'installation : ${Format.count(stats.totalBlocked)} requêtes bloquées sur " +
                    "${Format.count(stats.totalQueries)}, soit environ ${Format.bytes(stats.totalSavedBytes)} " +
                    "de trafic évité (estimation à ${StatsRepository.ESTIMATED_BYTES_PER_BLOCK / 1024} Ko par blocage).",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 4.dp),
            )
        }

        item { SectionTitle("Les plus bloqués aujourd'hui") }
        if (stats.topBlocked.isEmpty()) {
            item { EmptyLine("Rien de bloqué pour l'instant.") }
        }
        itemsIndexed(stats.topBlocked.take(10), key = { _, item -> "top_${item.first}" }) { index, (domain, count) ->
            Row(
                Modifier
                    .fillMaxWidth()
                    .clickable { selectedDomain = domain }
                    .padding(horizontal = 20.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "${index + 1}.",
                    style = MaterialTheme.typography.bodyMedium.copy(fontFeatureSettings = "tnum"),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.width(28.dp),
                )
                Text(domain, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                Text(Format.count(count), style = MaterialTheme.typography.bodyMedium.copy(fontFeatureSettings = "tnum"))
            }
        }

        item { SectionTitle("Journal des requêtes") }
        item {
            Column(Modifier.padding(horizontal = 20.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    LogFilter.entries.forEach { filter ->
                        FilterChip(
                            selected = logFilter == filter,
                            onClick = { logFilter = filter },
                            label = { Text(filter.title) },
                        )
                    }
                }
                OutlinedTextField(
                    value = search,
                    onValueChange = { search = it },
                    placeholder = { Text("Rechercher un domaine") },
                    leadingIcon = { Icon(Icons.Outlined.Search, contentDescription = null) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Text(
                    "Touchez un domaine pour l'autoriser ou le bloquer. Le journal reste sur le téléphone et s'efface à l'arrêt de l'application.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(vertical = 8.dp),
                )
            }
        }
        if (log.isEmpty()) {
            item { EmptyLine("Aucune requête à afficher.") }
        }
        // Pas de clé : deux requêtes identiques peuvent arriver dans la même milliseconde.
        items(log) { entry ->
            LogRow(entry, timeFormat.format(Date(entry.time))) { selectedDomain = entry.domain }
        }

        item {
            OutlinedButton(
                onClick = { confirmReset = true },
                modifier = Modifier.padding(20.dp),
            ) { Text("Réinitialiser les statistiques") }
        }
    }

    selectedDomain?.let { domain ->
        val verdict = stats.recent.firstOrNull { it.domain == domain }?.verdict
            ?: FilterRepository.matcher.value.verdict(domain)
        DomainDialog(domain, verdict, rules, onDismiss = { selectedDomain = null }, onMessage = onMessage)
    }
    if (confirmReset) {
        AlertDialog(
            onDismissRequest = { confirmReset = false },
            title = { Text("Réinitialiser les statistiques ?") },
            text = { Text("Les compteurs et le journal seront remis à zéro.") },
            confirmButton = {
                TextButton(onClick = {
                    StatsRepository.reset()
                    confirmReset = false
                }) { Text("Réinitialiser") }
            },
            dismissButton = { TextButton(onClick = { confirmReset = false }) { Text("Annuler") } },
        )
    }
}

@Composable
private fun KpiTiles(stats: StatsSnapshot) {
    val ratio = if (stats.todayQueries > 0) stats.todayBlocked.toDouble() / stats.todayQueries else 0.0
    Column(Modifier.padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            StatTile("Requêtes", Format.count(stats.todayQueries), Modifier.weight(1f))
            StatTile("Bloquées", Format.count(stats.todayBlocked), Modifier.weight(1f))
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            StatTile("Taux de blocage", Format.percent(ratio), Modifier.weight(1f))
            StatTile("Trafic économisé", Format.bytes(stats.todaySavedBytes), Modifier.weight(1f))
        }
    }
}

@Composable
private fun StatTile(label: String, value: String, modifier: Modifier) {
    Column(
        modifier
            .clip(RoundedCornerShape(16.dp))
            .background(BouclierTheme.colors.chartSurface)
            .padding(16.dp),
    ) {
        Text(label, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Spacer(Modifier.height(4.dp))
        Text(value, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
    }
}

/**
 * Colonnes empilées par heure : la part bloquée (couleur d'accent) part de la ligne
 * de base, la part autorisée (gris) au-dessus. Toucher une colonne affiche ses valeurs.
 */
@Composable
private fun HourlyChart(stats: StatsSnapshot) {
    val colors = BouclierTheme.colors
    val queries = stats.hourlyQueries
    val blocked = stats.hourlyBlocked
    var selectedHour by rememberSaveable { mutableIntStateOf(LocalTime.now().hour) }
    val axisMax = niceCeiling(maxOf(queries.maxOrNull() ?: 0, 4))
    val ticks = if (axisMax % 2 == 0) listOf(0, axisMax / 2, axisMax) else listOf(0, axisMax)

    val textMeasurer = rememberTextMeasurer()
    val labelStyle = MaterialTheme.typography.labelSmall.copy(
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        fontFeatureSettings = "tnum",
    )
    val density = LocalDensity.current
    val plotLeft = with(density) {
        textMeasurer.measure(Format.count(axisMax), labelStyle).size.width + 8.dp.toPx()
    }
    val selectionColor = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.06f)
    val busiest = queries.indices.maxByOrNull { queries[it] } ?: 0
    val summary = "Requêtes par heure aujourd'hui. Heure la plus active : ${busiest} h, " +
        "${queries[busiest]} requêtes dont ${blocked[busiest]} bloquées."

    Column(
        Modifier
            .padding(horizontal = 20.dp)
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(colors.chartSurface)
            .padding(16.dp),
    ) {
        Text("Heure par heure", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(6.dp))
        // Lecture de la colonne sélectionnée : la valeur d'abord, son libellé ensuite.
        Row(verticalAlignment = Alignment.Bottom) {
            Text(Format.count(blocked[selectedHour]), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.width(6.dp))
            Text(
                "bloquées sur ${Format.count(queries[selectedHour])} · de ${selectedHour} h à ${(selectedHour + 1) % 24} h",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(bottom = 3.dp),
            )
        }
        Spacer(Modifier.height(8.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            LegendKey(colors.chartBlocked)
            Spacer(Modifier.width(6.dp))
            Text("Bloquées", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.width(16.dp))
            LegendKey(colors.chartAllowed)
            Spacer(Modifier.width(6.dp))
            Text("Autorisées", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Spacer(Modifier.height(12.dp))
        Canvas(
            Modifier
                .fillMaxWidth()
                .height(170.dp)
                .semantics { contentDescription = summary }
                .pointerInput(plotLeft) {
                    detectTapGestures { offset -> selectedHour = hourAt(offset.x, plotLeft, size.width.toFloat()) }
                }
                .pointerInput(plotLeft) {
                    detectHorizontalDragGestures { change, _ ->
                        selectedHour = hourAt(change.position.x, plotLeft, size.width.toFloat())
                    }
                },
        ) {
            val xAxisHeight = 20.dp.toPx()
            val plotHeight = size.height - xAxisHeight
            val slot = (size.width - plotLeft) / 24f
            val barWidth = min(slot * 0.66f, 12.dp.toPx())
            val gap = 2.dp.toPx()
            val radius = min(4.dp.toPx(), barWidth / 2)

            // Quadrillage : traits fins et pleins, discrets.
            for (tick in ticks) {
                val y = plotHeight - plotHeight * tick / axisMax
                drawLine(colors.chartGrid, Offset(plotLeft, y), Offset(size.width, y), strokeWidth = 1f)
                val label = textMeasurer.measure(Format.count(tick), labelStyle)
                drawText(label, topLeft = Offset(plotLeft - label.size.width - 6.dp.toPx(), y - label.size.height / 2f))
            }
            // Colonne sélectionnée légèrement éclaircie.
            drawRect(selectionColor, topLeft = Offset(plotLeft + selectedHour * slot, 0f), size = Size(slot, plotHeight))

            for (hour in 0 until 24) {
                val total = queries[hour]
                if (total == 0) continue
                val blockedCount = blocked[hour].coerceIn(0, total)
                val x = plotLeft + hour * slot + (slot - barWidth) / 2
                val blockedHeight = plotHeight * blockedCount / axisMax
                val totalHeight = plotHeight * total / axisMax
                if (blockedCount > 0) {
                    drawBar(colors.chartBlocked, x, plotHeight - blockedHeight, barWidth, blockedHeight, roundTop = blockedCount == total, radius)
                }
                if (blockedCount < total) {
                    val top = plotHeight - totalHeight
                    val bottom = plotHeight - blockedHeight - if (blockedCount > 0) gap else 0f
                    drawBar(colors.chartAllowed, x, top, barWidth, maxOf(bottom - top, 1f), roundTop = true, radius)
                }
            }

            for (hour in listOf(0, 6, 12, 18)) {
                val label = textMeasurer.measure("$hour h", labelStyle)
                drawText(label, topLeft = Offset(plotLeft + hour * slot, plotHeight + 4.dp.toPx()))
            }
        }
    }
}

private fun hourAt(x: Float, plotLeft: Float, width: Float): Int {
    val slot = (width - plotLeft) / 24f
    return ((x - plotLeft) / slot).toInt().coerceIn(0, 23)
}

/** Barre à extrémité arrondie côté valeur, carrée côté ligne de base. */
private fun DrawScope.drawBar(color: Color, x: Float, top: Float, width: Float, height: Float, roundTop: Boolean, radius: Float) {
    if (!roundTop || height < radius * 2) {
        drawRect(color, topLeft = Offset(x, top), size = Size(width, height))
        return
    }
    val path = Path().apply {
        addRoundRect(
            RoundRect(
                left = x,
                top = top,
                right = x + width,
                bottom = top + height,
                topLeftCornerRadius = CornerRadius(radius),
                topRightCornerRadius = CornerRadius(radius),
                bottomRightCornerRadius = CornerRadius.Zero,
                bottomLeftCornerRadius = CornerRadius.Zero,
            ),
        )
    }
    drawPath(path, color)
}

/** Arrondit vers le haut à 1, 2 ou 5 × 10ⁿ pour des graduations lisibles. */
private fun niceCeiling(value: Int): Int {
    var magnitude = 1
    while (magnitude * 10 <= value) magnitude *= 10
    for (step in intArrayOf(1, 2, 5, 10)) {
        if (step * magnitude >= value) return step * magnitude
    }
    return 10 * magnitude
}

@Composable
private fun LegendKey(color: Color) {
    Box(
        Modifier
            .size(10.dp)
            .clip(RoundedCornerShape(2.dp))
            .background(color),
    )
}

/** Version tableau du graphique : chaque heure active avec ses valeurs. */
@Composable
private fun HourlyTable(stats: StatsSnapshot) {
    val tabular = MaterialTheme.typography.bodyMedium.copy(fontFeatureSettings = "tnum")
    Column(Modifier.padding(horizontal = 20.dp)) {
        Row(Modifier.padding(vertical = 4.dp)) {
            Text("Heure", style = MaterialTheme.typography.labelMedium, modifier = Modifier.weight(1f))
            Text("Requêtes", style = MaterialTheme.typography.labelMedium, modifier = Modifier.width(88.dp))
            Text("Bloquées", style = MaterialTheme.typography.labelMedium, modifier = Modifier.width(80.dp))
        }
        val hours = (0 until 24).filter { stats.hourlyQueries[it] > 0 }
        if (hours.isEmpty()) {
            Text("Aucune requête aujourd'hui.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        hours.forEach { hour ->
            Row(Modifier.padding(vertical = 2.dp)) {
                Text("$hour h – ${(hour + 1) % 24} h", style = tabular, modifier = Modifier.weight(1f))
                Text(Format.count(stats.hourlyQueries[hour]), style = tabular, modifier = Modifier.width(88.dp))
                Text(Format.count(stats.hourlyBlocked[hour]), style = tabular, modifier = Modifier.width(80.dp))
            }
        }
    }
}

@Composable
private fun LogRow(entry: QueryLogEntry, time: String, onClick: () -> Unit) {
    val colors = BouclierTheme.colors
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 20.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            if (entry.verdict.blocked) Icons.Outlined.Block else Icons.Outlined.CheckCircle,
            contentDescription = null,
            tint = if (entry.verdict.blocked) colors.danger else colors.accent,
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(entry.domain, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                "$time · ${DnsMessages.typeName(entry.type)} · ${verdictLabel(entry.verdict)}",
                style = MaterialTheme.typography.bodySmall.copy(fontFeatureSettings = "tnum"),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

private fun verdictLabel(verdict: Verdict): String = when (verdict) {
    Verdict.ALLOWED -> "Autorisée"
    Verdict.ALLOWED_BY_USER -> "Autorisée par vos règles"
    Verdict.BLOCKED -> "Bloquée"
    Verdict.BLOCKED_BY_USER -> "Bloquée par vos règles"
}

@Composable
private fun EmptyLine(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp),
    )
}

@Composable
private fun DomainDialog(domain: String, verdict: Verdict, rules: UserRules, onDismiss: () -> Unit, onMessage: (String) -> Unit) {
    val context = LocalContext.current
    val inRules = domain in rules.allowed || domain in rules.blocked
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(domain, maxLines = 2, overflow = TextOverflow.Ellipsis) },
        text = {
            Column {
                Text(
                    when (verdict) {
                        Verdict.BLOCKED -> "Bloqué par une liste de filtres."
                        Verdict.BLOCKED_BY_USER -> "Bloqué par vos règles."
                        Verdict.ALLOWED -> "Autorisé : il ne figure dans aucune liste activée."
                        Verdict.ALLOWED_BY_USER -> "Autorisé par vos règles."
                    },
                    style = MaterialTheme.typography.bodyMedium,
                )
                Spacer(Modifier.height(8.dp))
                if (domain !in rules.allowed) {
                    TextButton(onClick = {
                        FilterRepository.addUserRule(domain, allow = true)
                        onMessage("$domain est autorisé (effet sous une minute)")
                        onDismiss()
                    }) { Text("Toujours autoriser ce domaine") }
                }
                if (domain !in rules.blocked) {
                    TextButton(onClick = {
                        FilterRepository.addUserRule(domain, allow = false)
                        onMessage("$domain est bloqué (effet sous quelques minutes)")
                        onDismiss()
                    }) { Text("Toujours bloquer ce domaine") }
                }
                if (inRules) {
                    TextButton(onClick = {
                        FilterRepository.removeUserRule(domain)
                        onMessage("$domain retiré de vos règles")
                        onDismiss()
                    }) { Text("Retirer de mes règles") }
                }
                TextButton(onClick = {
                    context.getSystemService(ClipboardManager::class.java)
                        ?.setPrimaryClip(ClipData.newPlainText("Domaine", domain))
                    onMessage("Domaine copié")
                    onDismiss()
                }) { Text("Copier le domaine") }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Fermer") } },
    )
}
