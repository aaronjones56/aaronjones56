package io.github.aaronjones56.bouclier.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Block
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.ExpandLess
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.aaronjones56.bouclier.filter.FilterCategory
import io.github.aaronjones56.bouclier.filter.FilterListState
import io.github.aaronjones56.bouclier.filter.FilterRepository
import io.github.aaronjones56.bouclier.ui.components.BouclierSwitch
import io.github.aaronjones56.bouclier.ui.components.ScreenHeader
import io.github.aaronjones56.bouclier.ui.components.SectionTitle
import io.github.aaronjones56.bouclier.ui.components.SyncButton
import io.github.aaronjones56.bouclier.ui.components.icon
import io.github.aaronjones56.bouclier.ui.theme.BouclierTheme
import io.github.aaronjones56.bouclier.util.Format
import kotlinx.coroutines.launch

@Composable
fun ProtectionScreen(onMessage: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    val lists by FilterRepository.lists.collectAsStateWithLifecycle()
    val matcher by FilterRepository.matcher.collectAsStateWithLifecycle()
    val updating by FilterRepository.updating.collectAsStateWithLifecycle()
    val rules by FilterRepository.userRules.collectAsStateWithLifecycle()
    var showAddList by rememberSaveable { mutableStateOf(false) }

    LazyColumn(Modifier.fillMaxSize()) {
        item {
            val lastUpdate = lists.filter { it.enabled }.maxOfOrNull { it.updatedAt } ?: 0L
            ScreenHeader(
                title = "Protection",
                subtitle = when {
                    lists.none { it.enabled } -> "Aucune liste activée : seules vos règles s'appliquent"
                    matcher.usingBuiltinList -> "Listes pas encore téléchargées : protection de base active"
                    else -> "${Format.count(matcher.blockedDomainCount)} domaines bloqués · mis à jour " +
                        Format.relativeTime(lastUpdate).lowercase()
                },
                action = {
                    SyncButton(updating = updating) {
                        scope.launch { onMessage(updateMessage(FilterRepository.update(force = true))) }
                    }
                },
            )
        }

        for (category in FilterCategory.entries) {
            val inCategory = lists.filter { it.info.category == category }
            if (category == FilterCategory.CUSTOM) {
                item(key = "title_custom") { SectionTitle(category.title) }
                items(inCategory, key = { it.info.id }) { state ->
                    FilterListRow(state, onDelete = { FilterRepository.removeCustomList(state.info.id) })
                }
                item(key = "add_list") {
                    OutlinedButton(
                        onClick = { showAddList = true },
                        modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp),
                    ) {
                        Icon(Icons.Outlined.Add, contentDescription = null)
                        Spacer(Modifier.width(8.dp))
                        Text("Ajouter une liste")
                    }
                }
            } else if (inCategory.isNotEmpty()) {
                item(key = "title_${category.name}") { CategoryTitle(category) }
                items(inCategory, key = { it.info.id }) { state -> FilterListRow(state, onDelete = null) }
            }
        }

        item(key = "rules_title") { SectionTitle("Mes règles") }
        userRulesSection(
            key = "blocked",
            title = "Domaines bloqués",
            hint = "Toujours bloqués, ainsi que leurs sous-domaines.",
            domains = rules.blocked,
            allow = false,
            onMessage = onMessage,
        )
        userRulesSection(
            key = "allowed",
            title = "Domaines autorisés",
            hint = "Jamais bloqués, même s'ils figurent dans une liste.",
            domains = rules.allowed,
            allow = true,
            onMessage = onMessage,
        )

        item(key = "credits") {
            Text(
                "Les listes de filtres sont gratuites et maintenues par leurs auteurs (AdGuard, HaGeZi, " +
                    "Steven Black, malware-filter), sous leurs propres licences. Bouclier les télécharge " +
                    "directement depuis leur source.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(20.dp),
            )
        }
    }

    if (showAddList) {
        AddListDialog(
            onDismiss = { showAddList = false },
            onAdd = { name, url ->
                val error = FilterRepository.addCustomList(name, url)
                if (error == null) {
                    showAddList = false
                    onMessage("Liste ajoutée : téléchargement en cours")
                }
                error
            },
        )
    }
}

@Composable
private fun CategoryTitle(category: FilterCategory) {
    Row(
        Modifier.padding(start = 20.dp, end = 20.dp, top = 24.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(category.icon, contentDescription = null, tint = BouclierTheme.colors.accent, modifier = Modifier.size(22.dp))
        Spacer(Modifier.width(10.dp))
        Text(category.title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, color = BouclierTheme.colors.accent)
    }
}

@Composable
private fun FilterListRow(state: FilterListState, onDelete: (() -> Unit)?) {
    Row(
        Modifier
            .fillMaxWidth()
            .toggleable(
                value = state.enabled,
                role = Role.Switch,
                onValueChange = { FilterRepository.setEnabled(state.info.id, it) },
            )
            .padding(start = 20.dp, end = if (onDelete != null) 4.dp else 20.dp, top = 12.dp, bottom = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(state.info.name, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Medium)
            Text(
                state.info.description,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.height(2.dp))
            ListStatus(state)
        }
        Spacer(Modifier.width(12.dp))
        BouclierSwitch(checked = state.enabled)
        if (onDelete != null) {
            IconButton(onClick = onDelete) {
                Icon(Icons.Outlined.Delete, contentDescription = "Supprimer la liste ${state.info.name}")
            }
        }
    }
}

@Composable
private fun ListStatus(state: FilterListState) {
    val style = MaterialTheme.typography.bodySmall
    when {
        state.downloading -> Row(verticalAlignment = Alignment.CenterVertically) {
            CircularProgressIndicator(Modifier.size(12.dp), strokeWidth = 2.dp)
            Spacer(Modifier.width(6.dp))
            Text("Téléchargement…", style = style, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        state.error != null -> Text("Erreur : ${state.error}", style = style, color = BouclierTheme.colors.danger)
        state.updatedAt > 0 -> Text(
            "${Format.count(state.domainCount)} domaines · ${Format.relativeTime(state.updatedAt)}" +
                (state.info.credit?.let { " · $it" } ?: ""),
            style = style,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        else -> Text(
            if (state.enabled) "En attente de téléchargement" else (state.info.credit ?: "Non téléchargée"),
            style = style,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** Section repliable « Domaines bloqués » ou « Domaines autorisés ». */
private fun LazyListScope.userRulesSection(
    key: String,
    title: String,
    hint: String,
    domains: Set<String>,
    allow: Boolean,
    onMessage: (String) -> Unit,
) {
    item(key = "rules_$key") {
        var expanded by rememberSaveable { mutableStateOf(false) }
        var input by rememberSaveable { mutableStateOf("") }
        val accent = BouclierTheme.colors.accent
        Column {
            Row(
                Modifier
                    .fillMaxWidth()
                    .clickable { expanded = !expanded }
                    .padding(horizontal = 20.dp, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    if (allow) Icons.Outlined.CheckCircle else Icons.Outlined.Block,
                    contentDescription = null,
                    tint = if (allow) accent else BouclierTheme.colors.danger,
                )
                Spacer(Modifier.width(16.dp))
                Column(Modifier.weight(1f)) {
                    Text("$title (${domains.size})", style = MaterialTheme.typography.bodyLarge)
                    Text(hint, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Icon(
                    if (expanded) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore,
                    contentDescription = if (expanded) "Replier" else "Déplier",
                )
            }
            if (expanded) {
                val submit: () -> Unit = {
                    val domain = FilterRepository.addUserRule(input, allow)
                    if (domain == null) {
                        onMessage("« $input » n'est pas un nom de domaine valide")
                    } else {
                        onMessage(if (allow) "$domain est autorisé" else "$domain est bloqué")
                        input = ""
                    }
                }
                Row(
                    Modifier.padding(start = 20.dp, end = 12.dp, bottom = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    OutlinedTextField(
                        value = input,
                        onValueChange = { input = it },
                        placeholder = { Text("exemple.com") },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Done),
                        keyboardActions = KeyboardActions(onDone = { if (input.isNotBlank()) submit() }),
                        modifier = Modifier.weight(1f),
                    )
                    IconButton(onClick = submit, enabled = input.isNotBlank()) {
                        Icon(Icons.Outlined.Add, contentDescription = "Ajouter")
                    }
                }
                if (domains.isEmpty()) {
                    Text(
                        "Aucun domaine pour l'instant.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp),
                    )
                }
                domains.sorted().forEach { domain ->
                    Row(
                        Modifier.padding(start = 20.dp, end = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween,
                    ) {
                        Text(domain, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
                        IconButton(onClick = { FilterRepository.removeUserRule(domain) }) {
                            Icon(Icons.Outlined.Delete, contentDescription = "Retirer $domain")
                        }
                    }
                }
            }
            HorizontalDivider(Modifier.padding(horizontal = 20.dp), color = MaterialTheme.colorScheme.outlineVariant)
        }
    }
}

@Composable
private fun AddListDialog(onDismiss: () -> Unit, onAdd: (name: String, url: String) -> String?) {
    var name by rememberSaveable { mutableStateOf("") }
    var url by rememberSaveable { mutableStateOf("https://") }
    var error by rememberSaveable { mutableStateOf<String?>(null) }
    val currentError = error
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Ajouter une liste") },
        text = {
            Column {
                Text(
                    "Formats acceptés : fichier hosts, liste de domaines ou règles Adblock (||domaine^).",
                    style = MaterialTheme.typography.bodyMedium,
                )
                Spacer(Modifier.height(12.dp))
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text("Nom (facultatif)") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(
                    value = url,
                    onValueChange = {
                        url = it
                        error = null
                    },
                    label = { Text("Adresse de la liste") },
                    singleLine = true,
                    isError = currentError != null,
                    supportingText = if (currentError != null) {
                        { Text(currentError) }
                    } else {
                        null
                    },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = { TextButton(onClick = { error = onAdd(name, url) }) { Text("Ajouter") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Annuler") } },
    )
}
