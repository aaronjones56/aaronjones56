package io.github.aaronjones56.bouclier.vpn

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.system.OsConstants
import android.util.Log
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import io.github.aaronjones56.bouclier.AppScope
import io.github.aaronjones56.bouclier.R
import io.github.aaronjones56.bouclier.data.DnsProvider
import io.github.aaronjones56.bouclier.data.SettingsRepository
import io.github.aaronjones56.bouclier.filter.FilterRepository
import io.github.aaronjones56.bouclier.stats.StatsRepository
import io.github.aaronjones56.bouclier.ui.MainActivity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.IOException
import java.net.InetAddress
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit

/**
 * VPN local qui ne capte que le DNS : Android envoie toutes les requêtes DNS au
 * serveur virtuel de l'interface TUN, et le reste du trafic ne passe jamais par
 * l'application. Les requêtes vers des domaines publicitaires reçoivent une
 * réponse vide ; les autres sont transmises au vrai serveur DNS.
 */
class BouclierVpnService : VpnService() {

    enum class State { STOPPED, STARTING, RUNNING }

    private val control = Executors.newSingleThreadExecutor { Thread(it, "bouclier-vpn-control") }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var jobs: List<Job> = emptyList()

    // Accédés uniquement depuis le fil [control].
    private var tunnel: ParcelFileDescriptor? = null
    private var worker: TunnelWorker? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private val recentFailures = ArrayDeque<Long>()

    /** Identifiant de la dernière commande reçue : un arrêt ne doit pas annuler un démarrage plus récent. */
    @Volatile
    private var latestStartId = 0

    @Volatile
    private var networkDns: List<InetAddress> = emptyList()

    @Volatile
    private var upstreams: List<InetAddress> = DnsProvider.FALLBACK

    private lateinit var connectivity: ConnectivityManager
    private lateinit var notifications: NotificationManager
    private lateinit var forwarder: UpstreamForwarder

    override fun onCreate() {
        super.onCreate()
        connectivity = getSystemService(ConnectivityManager::class.java)
        notifications = getSystemService(NotificationManager::class.java)
        forwarder = UpstreamForwarder(protect = { protect(it) }, servers = { upstreams })
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        latestStartId = startId
        if (intent?.action == ACTION_STOP) {
            onControlThread { shutdown(userRequested = true, stopId = startId) }
            return START_NOT_STICKY
        }
        // Démarrage demandé par l'application, par Android (VPN permanent) ou relance
        // automatique du service après l'arrêt du processus.
        goForeground()
        onControlThread { startProtection() }
        return START_STICKY
    }

    override fun onRevoke() {
        onControlThread {
            shutdown(userRequested = true, error = "La protection a été désactivée par Android ou par une autre application VPN.")
        }
    }

    override fun onDestroy() {
        scope.cancel()
        onControlThread {
            if (worker != null || tunnel != null) {
                // Arrêt imposé par le système : on libère tout sans toucher aux réglages.
                releaseResources()
                _state.value = State.STOPPED
            }
        }
        control.shutdown()
        try {
            control.awaitTermination(3, TimeUnit.SECONDS)
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        super.onDestroy()
    }

    /** Exécute [block] sur le fil qui pilote le VPN (ignoré une fois le service détruit). */
    private fun onControlThread(block: () -> Unit) {
        try {
            control.execute { block() }
        } catch (e: RejectedExecutionException) {
            Log.w(TAG, "Service déjà arrêté", e)
        }
    }

    private fun goForeground() {
        val stats = StatsRepository.snapshot()
        val notification = ProtectionNotification.build(this, stats.todayBlocked, stats.todaySavedBytes)
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(ProtectionNotification.NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(ProtectionNotification.NOTIFICATION_ID, notification)
        }
    }

    private fun startProtection() {
        if (worker != null) {
            _state.value = State.RUNNING
            return
        }
        _state.value = State.STARTING
        // Un arrêt traité juste avant a pu retirer la notification : on repasse au premier plan.
        goForeground()
        if (prepare(this) != null) {
            shutdown(userRequested = false, error = "Autorisation VPN manquante : rouvrez Bouclier pour réactiver la protection.")
            return
        }
        startNetworkMonitoring()
        if (!openTunnel()) {
            shutdown(userRequested = false, error = "Impossible de démarrer le VPN local.")
            return
        }
        SettingsRepository.update { it.copy(protectionWanted = true) }
        _lastError.value = null
        _state.value = State.RUNNING
        startJobs()
    }

    /** Crée l'interface TUN et lance sa lecture. Ne ferme pas une éventuelle interface précédente. */
    private fun openTunnel(): Boolean {
        val builder = Builder()
        // Plages réservées à la documentation (RFC 5737) : jamais utilisées par un vrai réseau.
        val prefix = ADDRESS_PREFIXES.firstOrNull { prefix ->
            try {
                builder.addAddress("$prefix.1", 24)
                true
            } catch (e: IllegalArgumentException) {
                false
            }
        } ?: return false
        val dnsServer = "$prefix.2"
        builder.addDnsServer(dnsServer)
        builder.addRoute(dnsServer, 32)
        builder.setMtu(TunnelWorker.MAX_PACKET_SIZE)
        builder.setBlocking(true)
        builder.setSession(getString(R.string.app_name))
        builder.setConfigureIntent(
            PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE),
        )
        // Seul le DNS passe par le VPN : le reste du trafic, IPv4 comme IPv6, ne doit pas être bloqué.
        builder.allowFamily(OsConstants.AF_INET)
        builder.allowFamily(OsConstants.AF_INET6)
        // Sinon Android considère le VPN comme une connexion facturée à l'usage, même en Wi-Fi.
        if (Build.VERSION.SDK_INT >= 29) builder.setMetered(false)
        for (app in SettingsRepository.state.value.excludedApps + packageName) {
            try {
                builder.addDisallowedApplication(app)
            } catch (e: PackageManager.NameNotFoundException) {
                // application désinstallée entre-temps
            }
        }

        val descriptor = try {
            builder.establish()
        } catch (e: Exception) {
            Log.w(TAG, "Création de l'interface VPN impossible", e)
            null
        } ?: return false

        val handler = DnsPacketHandler(
            dnsAddress = InetAddress.getByName(dnsServer).address,
            matcher = { FilterRepository.matcher.value },
            blockResponse = { SettingsRepository.state.value.blockResponse },
            onQuery = StatsRepository::record,
        )
        tunnel = descriptor
        worker = TunnelWorker(descriptor, handler, forwarder, onFailure = { onControlThread(::onTunnelFailure) })
            .also { it.start() }
        return true
    }

    /**
     * Remplace l'interface TUN par une nouvelle (applications exclues modifiées, erreur…).
     * La nouvelle interface est créée avant de fermer l'ancienne : Android bascule de
     * l'une à l'autre sans couper le réseau des applications.
     */
    private fun replaceTunnel(): Boolean {
        val oldTunnel = tunnel
        worker?.stop()
        worker = null
        tunnel = null
        val opened = openTunnel()
        closeQuietly(oldTunnel)
        return opened
    }

    private fun onTunnelFailure() {
        if (worker == null) return
        val now = SystemClock.elapsedRealtime()
        recentFailures.addLast(now)
        while (recentFailures.isNotEmpty() && now - recentFailures.first() > 60_000) recentFailures.removeFirst()
        if (recentFailures.size > MAX_RESTARTS_PER_MINUTE || !replaceTunnel()) {
            shutdown(userRequested = false, error = "Le VPN local s'est arrêté de façon inattendue.")
        }
    }

    /**
     * Coupe la protection. [stopId] : commande qui a demandé l'arrêt ; si un démarrage plus
     * récent est déjà en file, le service n'est pas détruit et ce démarrage s'exécutera ensuite.
     */
    private fun shutdown(userRequested: Boolean, error: String? = null, stopId: Int = latestStartId) {
        releaseResources()
        StatsRepository.save()
        if (userRequested) SettingsRepository.update { it.copy(protectionWanted = false) }
        if (error != null) _lastError.value = error
        _state.value = State.STOPPED
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf(stopId)
    }

    private fun releaseResources() {
        jobs.forEach { it.cancel() }
        jobs = emptyList()
        worker?.stop()
        worker = null
        closeQuietly(tunnel)
        tunnel = null
        stopNetworkMonitoring()
    }

    @OptIn(FlowPreview::class)
    private fun startJobs() {
        jobs.forEach { it.cancel() }
        jobs = listOf(
            // Compteurs de la notification.
            scope.launch {
                StatsRepository.snapshots(NOTIFICATION_REFRESH_MS)
                    .map { it.todayBlocked to it.todaySavedBytes }
                    .distinctUntilChanged()
                    .collect { (blocked, saved) ->
                        notifications.notify(
                            ProtectionNotification.NOTIFICATION_ID,
                            ProtectionNotification.build(this@BouclierVpnService, blocked, saved),
                        )
                    }
            },
            // Sauvegarde régulière des statistiques.
            scope.launch {
                while (isActive) {
                    delay(STATS_SAVE_INTERVAL_MS)
                    StatsRepository.save()
                }
            },
            // Applications exclues modifiées : nouvelle interface.
            scope.launch {
                SettingsRepository.state
                    .map { it.excludedApps }
                    .distinctUntilChanged()
                    .drop(1)
                    .debounce(EXCLUSION_DEBOUNCE_MS)
                    .collect {
                        onControlThread {
                            if (worker != null && !replaceTunnel()) {
                                shutdown(userRequested = false, error = "Impossible de relancer le VPN local.")
                            }
                        }
                    }
            },
            // Serveur DNS choisi dans les réglages.
            scope.launch {
                SettingsRepository.state
                    .map { it.dnsProvider to it.customDns }
                    .distinctUntilChanged()
                    .collect { refreshUpstreams() }
            },
            scope.launch { keepFiltersUpToDate() },
        )
    }

    /** Télécharge les listes manquantes, puis les met à jour régulièrement (Wi-Fi uniquement). */
    private suspend fun keepFiltersUpToDate() {
        while (true) {
            val missing = FilterRepository.hasMissingLists()
            val autoUpdate = SettingsRepository.state.value.autoUpdate
            if (missing || (autoUpdate && FilterRepository.isUpdateDue() && isUnmetered())) {
                // Lancé hors du service : un téléchargement commencé va à son terme même si
                // la protection est coupée entre-temps.
                AppScope.launch { FilterRepository.update(force = false) }.join()
            }
            delay(if (FilterRepository.hasMissingLists()) RETRY_MISSING_LISTS_MS else UPDATE_CHECK_INTERVAL_MS)
        }
    }

    private fun isUnmetered(): Boolean {
        val capabilities = connectivity.getNetworkCapabilities(connectivity.activeNetwork) ?: return false
        return capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
    }

    // --- Serveurs DNS ---

    private fun startNetworkMonitoring() {
        if (networkCallback != null) return
        updateNetworkDns(connectivity.activeNetwork?.let { connectivity.getLinkProperties(it) })
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
                updateNetworkDns(linkProperties)
            }
        }
        try {
            // L'application est exclue de son propre VPN : son réseau par défaut est le vrai réseau.
            connectivity.registerDefaultNetworkCallback(callback)
            networkCallback = callback
        } catch (e: RuntimeException) {
            Log.w(TAG, "Suivi du réseau impossible", e)
        }
    }

    private fun stopNetworkMonitoring() {
        networkCallback?.let {
            try {
                connectivity.unregisterNetworkCallback(it)
            } catch (e: RuntimeException) {
                // déjà désinscrit
            }
        }
        networkCallback = null
    }

    private fun updateNetworkDns(linkProperties: LinkProperties?) {
        networkDns = linkProperties?.dnsServers.orEmpty().filterNot { address ->
            val text = address.hostAddress.orEmpty()
            ADDRESS_PREFIXES.any { text.startsWith("$it.") }
        }
        refreshUpstreams()
    }

    private fun refreshUpstreams() {
        val settings = SettingsRepository.state.value
        upstreams = when (settings.dnsProvider) {
            DnsProvider.AUTO -> (networkDns + DnsProvider.FALLBACK).distinct()
            DnsProvider.CUSTOM -> settings.customDnsAddresses.ifEmpty { DnsProvider.FALLBACK }
            else -> settings.dnsProvider.addresses
        }
    }

    private fun closeQuietly(descriptor: ParcelFileDescriptor?) {
        try {
            descriptor?.close()
        } catch (e: IOException) {
            // déjà fermé
        }
    }

    companion object {
        private const val TAG = "BouclierVpnService"
        const val ACTION_START = "io.github.aaronjones56.bouclier.action.START"
        const val ACTION_STOP = "io.github.aaronjones56.bouclier.action.STOP"

        private val ADDRESS_PREFIXES = listOf("192.0.2", "198.51.100", "203.0.113")
        private const val NOTIFICATION_REFRESH_MS = 3_000L
        private const val STATS_SAVE_INTERVAL_MS = 60_000L
        private const val EXCLUSION_DEBOUNCE_MS = 1_500L
        private const val UPDATE_CHECK_INTERVAL_MS = 6 * 3600_000L
        private const val RETRY_MISSING_LISTS_MS = 5 * 60_000L
        private const val MAX_RESTARTS_PER_MINUTE = 3

        private val _state = MutableStateFlow(State.STOPPED)
        val state: StateFlow<State> = _state.asStateFlow()

        private val _lastError = MutableStateFlow<String?>(null)

        /** Dernière erreur à signaler à l'utilisateur, effacée avec [clearError]. */
        val lastError: StateFlow<String?> = _lastError.asStateFlow()

        fun start(context: Context) {
            val intent = Intent(context, BouclierVpnService::class.java).setAction(ACTION_START)
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context) {
            context.startService(Intent(context, BouclierVpnService::class.java).setAction(ACTION_STOP))
        }

        fun clearError() {
            _lastError.value = null
        }
    }
}
