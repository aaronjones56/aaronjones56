package io.github.aaronjones56.bouclier

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.util.Log
import io.github.aaronjones56.bouclier.data.SettingsRepository
import io.github.aaronjones56.bouclier.vpn.BouclierVpnService

/** Relance la protection au démarrage du téléphone et après une mise à jour de l'application. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action != Intent.ACTION_BOOT_COMPLETED && action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        val settings = SettingsRepository.state.value
        if (!settings.protectionWanted) return
        if (action == Intent.ACTION_BOOT_COMPLETED && !settings.startOnBoot) return
        // Autorisation VPN retirée entre-temps : il faudra rouvrir l'application.
        if (VpnService.prepare(context) != null) return
        try {
            BouclierVpnService.start(context)
        } catch (e: RuntimeException) {
            Log.w("BootReceiver", "Impossible de relancer la protection", e)
        }
    }
}
