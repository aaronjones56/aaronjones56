package io.github.aaronjones56.bouclier.ui.youtube

import android.os.Build
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.SmartDisplay
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import io.github.aaronjones56.bouclier.youtube.app.YoutubeAppAds

/** Explique comment activer le blocage des pubs dans l'appli YouTube (une seule fois). */
@Composable
fun YoutubeAppSetupDialog(enabled: Boolean, onDismiss: () -> Unit) {
    val context = LocalContext.current
    AlertDialog(
        onDismissRequest = onDismiss,
        icon = { Icon(Icons.Outlined.SmartDisplay, contentDescription = null) },
        title = { Text(if (enabled) "Pubs de l'appli YouTube : activé" else "Bloquer les pubs dans l'appli YouTube") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                Paragraph(
                    "Utilisez YouTube comme d'habitude. Dès qu'une pub apparaît, Bouclier coupe le son, la cache " +
                        "derrière un écran noir et touche « Ignorer » dès que YouTube le permet (au bout de 5 s). " +
                        "Les pubs qu'on ne peut pas ignorer restent muettes et cachées jusqu'à la fin.",
                )
                if (!enabled) {
                    Title("À faire une seule fois")
                    Paragraph(
                        "1. Touchez « Ouvrir les réglages ».\n" +
                            "2. Dans « Applications installées » (ou « Services téléchargés »), choisissez " +
                            "« Bouclier — pubs YouTube » et activez-le.\n" +
                            "3. Android prévient que le service peut voir l'écran : il ne regarde que l'appli " +
                            "YouTube, rien n'est enregistré ni envoyé.",
                    )
                    if (Build.VERSION.SDK_INT >= 33) {
                        Title("« Paramètre restreint » ?")
                        Paragraph(
                            "Android bloque ce réglage pour les applis installées hors Play Store. Touchez « Infos " +
                                "de l'appli », puis le menu ⋮ en haut à droite › « Autoriser les paramètres " +
                                "restreints », et recommencez l'étape 2.",
                        )
                    }
                }
                Title("Pourquoi pas mieux ?")
                Paragraph(
                    "Dans l'appli YouTube, la pub arrive chiffrée avec la vidéo : sans root, aucune appli ne peut " +
                        "l'empêcher de se charger. Pour ne voir aucune pub du tout, ouvrez la vidéo dans le lecteur " +
                        "de Bouclier (Partager › Regarder sans pub).",
                )
            }
        },
        confirmButton = {
            TextButton(onClick = {
                YoutubeAppAds.openAccessibilitySettings(context)
                onDismiss()
            }) { Text(if (enabled) "Réglages" else "Ouvrir les réglages") }
        },
        dismissButton = {
            if (!enabled && Build.VERSION.SDK_INT >= 33) {
                TextButton(onClick = { YoutubeAppAds.openAppDetails(context) }) { Text("Infos de l'appli") }
            } else {
                TextButton(onClick = onDismiss) { Text("Fermer") }
            }
        },
    )
}

@Composable
private fun Title(text: String) {
    Text(text, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
    Spacer(Modifier.height(4.dp))
}

@Composable
private fun Paragraph(text: String) {
    Text(text, style = MaterialTheme.typography.bodyMedium)
    Spacer(Modifier.height(14.dp))
}
