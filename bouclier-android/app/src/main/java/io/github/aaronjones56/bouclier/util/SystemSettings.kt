package io.github.aaronjones56.bouclier.util

import android.annotation.SuppressLint
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.net.toUri

/** Raccourcis vers les écrans de réglages d'Android et informations système utiles. */
object SystemSettings {

    fun openVpnSettings(context: Context) = open(context, Intent(Settings.ACTION_VPN_SETTINGS))

    /** Réglages « Réseau et Internet », où se trouve le DNS privé. */
    fun openNetworkSettings(context: Context) = open(context, Intent(Settings.ACTION_WIRELESS_SETTINGS))

    fun openNotificationSettings(context: Context) = open(
        context,
        Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName),
    )

    /** Demande à Android de ne pas couper l'application pour économiser la batterie. */
    @SuppressLint("BatteryLife") // application installée hors Play Store : c'est un VPN qui doit rester actif
    fun requestIgnoreBatteryOptimizations(context: Context) {
        val request = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, "package:${context.packageName}".toUri())
        if (!open(context, request, fallback = false)) {
            open(context, Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        }
    }

    fun isIgnoringBatteryOptimizations(context: Context): Boolean =
        context.getSystemService(PowerManager::class.java)?.isIgnoringBatteryOptimizations(context.packageName) == true

    /**
     * Nom d'hôte du « DNS privé » s'il est réglé en mode strict. Dans ce mode, Android
     * chiffre les requêtes DNS et les envoie directement à ce serveur : elles échappent
     * alors au filtrage.
     */
    fun privateDnsHostname(context: Context): String? {
        if (Build.VERSION.SDK_INT < 28) return null
        val connectivity = context.getSystemService(ConnectivityManager::class.java) ?: return null
        val network = connectivity.activeNetwork ?: return null
        return connectivity.getLinkProperties(network)?.privateDnsServerName
    }

    private fun open(context: Context, intent: Intent, fallback: Boolean = true): Boolean {
        return try {
            context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (e: ActivityNotFoundException) {
            if (fallback) open(context, Intent(Settings.ACTION_SETTINGS), fallback = false) else false
        } catch (e: SecurityException) {
            false
        }
    }
}
