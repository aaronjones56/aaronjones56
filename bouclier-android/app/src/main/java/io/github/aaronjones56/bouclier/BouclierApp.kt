package io.github.aaronjones56.bouclier

import android.app.Application
import io.github.aaronjones56.bouclier.data.SettingsRepository
import io.github.aaronjones56.bouclier.filter.FilterRepository
import io.github.aaronjones56.bouclier.stats.StatsRepository
import io.github.aaronjones56.bouclier.vpn.ProtectionNotification
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

/** Portée des tâches qui doivent survivre à un écran ou au service (téléchargements…). */
object AppScope : CoroutineScope by CoroutineScope(SupervisorJob() + Dispatchers.Default)

class BouclierApp : Application() {
    override fun onCreate() {
        super.onCreate()
        SettingsRepository.init(this)
        StatsRepository.init(this)
        FilterRepository.init(this)
        ProtectionNotification.createChannel(this)
    }
}
