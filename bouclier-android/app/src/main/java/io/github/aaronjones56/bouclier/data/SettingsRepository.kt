package io.github.aaronjones56.bouclier.data

import android.content.Context
import android.content.SharedPreferences
import androidx.core.content.edit
import io.github.aaronjones56.bouclier.net.BlockResponse
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.net.InetAddress

/** Serveur DNS auquel sont transmises les requêtes autorisées. */
enum class DnsProvider(val title: String, val detail: String, val servers: List<String>) {
    AUTO("Automatique", "Le DNS du réseau Wi-Fi ou mobile", emptyList()),
    CLOUDFLARE("Cloudflare", "1.1.1.1 · rapide et respectueux de la vie privée", listOf("1.1.1.1", "1.0.0.1", "2606:4700:4700::1111")),
    QUAD9("Quad9", "9.9.9.9 · bloque en plus les domaines malveillants", listOf("9.9.9.9", "149.112.112.112", "2620:fe::fe")),
    GOOGLE("Google", "8.8.8.8", listOf("8.8.8.8", "8.8.4.4", "2001:4860:4860::8888")),
    ADGUARD("AdGuard DNS", "94.140.14.14 · bloque en plus les publicités", listOf("94.140.14.14", "94.140.15.15", "2a10:50c0::ad1:ff")),
    CUSTOM("Personnalisé", "Vos propres adresses IP", emptyList()),
    ;

    val addresses: List<InetAddress> by lazy { servers.mapNotNull(IpAddresses::parse) }

    companion object {
        /** Serveurs de secours si le réseau n'annonce aucun DNS ou si celui-ci ne répond pas. */
        val FALLBACK: List<InetAddress> by lazy { listOf("1.1.1.1", "8.8.8.8").mapNotNull(IpAddresses::parse) }
    }
}

enum class ThemeMode(val title: String) {
    DARK("Sombre"),
    LIGHT("Clair"),
    SYSTEM("Comme le système"),
}

data class Settings(
    /** La protection doit être active (redémarrage du téléphone, mise à jour de l'appli). */
    val protectionWanted: Boolean = false,
    val startOnBoot: Boolean = true,
    val autoUpdate: Boolean = true,
    val dnsProvider: DnsProvider = DnsProvider.AUTO,
    val customDns: String = "",
    val blockResponse: BlockResponse = BlockResponse.NULL_IP,
    val theme: ThemeMode = ThemeMode.DARK,
    /** Applications dont le trafic ne passe pas par le filtre. */
    val excludedApps: Set<String> = emptySet(),
    /** Cartes de conseils masquées sur l'écran d'accueil. */
    val dismissedTips: Set<String> = emptySet(),
) {
    val customDnsAddresses: List<InetAddress>
        get() = customDns.split(',', ' ', ';', '\n').mapNotNull { IpAddresses.parse(it.trim()) }
}

/** Réglages de l'application, enregistrés dans les SharedPreferences. */
object SettingsRepository {
    private lateinit var prefs: SharedPreferences
    private val _state = MutableStateFlow(Settings())
    val state: StateFlow<Settings> = _state.asStateFlow()

    fun init(context: Context) {
        prefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)
        _state.value = read()
    }

    fun update(transform: (Settings) -> Settings) {
        synchronized(this) {
            val settings = transform(_state.value)
            if (settings == _state.value) return
            write(settings)
            _state.value = settings
        }
    }

    fun setAppExcluded(packageName: String, excluded: Boolean) = update {
        it.copy(excludedApps = if (excluded) it.excludedApps + packageName else it.excludedApps - packageName)
    }

    fun dismissTip(id: String) = update { it.copy(dismissedTips = it.dismissedTips + id) }

    private fun read(): Settings {
        val defaults = Settings()
        return Settings(
            protectionWanted = prefs.getBoolean("protection_wanted", defaults.protectionWanted),
            startOnBoot = prefs.getBoolean("start_on_boot", defaults.startOnBoot),
            autoUpdate = prefs.getBoolean("auto_update", defaults.autoUpdate),
            dnsProvider = enumValue(prefs.getString("dns_provider", null), defaults.dnsProvider),
            customDns = prefs.getString("custom_dns", defaults.customDns).orEmpty(),
            blockResponse = enumValue(prefs.getString("block_response", null), defaults.blockResponse),
            theme = enumValue(prefs.getString("theme", null), defaults.theme),
            excludedApps = prefs.getStringSet("excluded_apps", null).orEmpty().toSet(),
            dismissedTips = prefs.getStringSet("dismissed_tips", null).orEmpty().toSet(),
        )
    }

    private fun write(settings: Settings) {
        prefs.edit {
            putBoolean("protection_wanted", settings.protectionWanted)
            putBoolean("start_on_boot", settings.startOnBoot)
            putBoolean("auto_update", settings.autoUpdate)
            putString("dns_provider", settings.dnsProvider.name)
            putString("custom_dns", settings.customDns)
            putString("block_response", settings.blockResponse.name)
            putString("theme", settings.theme.name)
            putStringSet("excluded_apps", HashSet(settings.excludedApps))
            putStringSet("dismissed_tips", HashSet(settings.dismissedTips))
        }
    }

    private inline fun <reified T : Enum<T>> enumValue(name: String?, default: T): T =
        enumValues<T>().firstOrNull { it.name == name } ?: default
}

/** Analyse d'adresses IP littérales, sans jamais déclencher de résolution DNS. */
object IpAddresses {
    private val IPV4 = Regex("""^(25[0-5]|2[0-4]\d|1?\d?\d)(\.(25[0-5]|2[0-4]\d|1?\d?\d)){3}$""")
    private val IPV6 = Regex("""^[0-9a-fA-F:.]+$""")

    fun parse(text: String): InetAddress? {
        if (text.isEmpty()) return null
        val literal = IPV4.matches(text) || (text.contains(':') && IPV6.matches(text))
        if (!literal) return null
        return try {
            InetAddress.getByName(text)
        } catch (e: Exception) {
            null
        }
    }
}
