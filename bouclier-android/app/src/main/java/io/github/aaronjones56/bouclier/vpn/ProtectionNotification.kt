package io.github.aaronjones56.bouclier.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.github.aaronjones56.bouclier.R
import io.github.aaronjones56.bouclier.ui.MainActivity
import io.github.aaronjones56.bouclier.util.Format

/** Notification permanente affichée tant que la protection est active. */
object ProtectionNotification {
    const val CHANNEL_ID = "protection"
    const val NOTIFICATION_ID = 1

    fun createChannel(context: Context) {
        val channel = NotificationChannel(CHANNEL_ID, "Protection active", NotificationManager.IMPORTANCE_LOW).apply {
            description = "Notification permanente affichée tant que la protection est activée."
            setShowBadge(false)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        context.getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    fun build(context: Context, blocked: Int, savedBytes: Long): Notification {
        val flags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        val openApp = PendingIntent.getActivity(
            context, 0,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            flags,
        )
        val openStats = PendingIntent.getActivity(
            context, 1,
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra(MainActivity.EXTRA_TAB, MainActivity.TAB_STATS),
            flags,
        )
        val stop = PendingIntent.getService(
            context, 2,
            Intent(context, BouclierVpnService::class.java).setAction(BouclierVpnService.ACTION_STOP),
            flags,
        )
        val blockedLine = "Bloqué : ${Format.count(blocked.toLong())}"
        val savedLine = "Trafic économisé : ${Format.bytes(savedBytes)}"
        return NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setColor(ContextCompat.getColor(context, R.color.brand_green))
            .setContentTitle("Bloque les publicités et les traqueurs")
            .setContentText("$blockedLine · $savedLine")
            .setStyle(NotificationCompat.BigTextStyle().bigText("$blockedLine\n$savedLine"))
            .setContentIntent(openApp)
            .addAction(0, "Désactiver", stop)
            .addAction(0, "Statistiques", openStats)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }
}
