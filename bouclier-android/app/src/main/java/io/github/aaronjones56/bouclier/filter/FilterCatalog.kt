package io.github.aaronjones56.bouclier.filter

/** Catégories de protection, affichées sous forme d'icônes sur l'écran d'accueil. */
enum class FilterCategory(val title: String) {
    ADS("Publicités"),
    TRACKERS("Traqueurs"),
    SECURITY("Malwares et arnaques"),
    SOCIAL("Réseaux sociaux"),
    ADULT("Contenu pour adultes"),
    GAMBLING("Jeux d'argent"),
    CUSTOM("Listes personnalisées"),
}

/** Description d'une liste de filtres téléchargeable. */
data class FilterListInfo(
    val id: String,
    val name: String,
    val description: String,
    val urls: List<String>,
    val category: FilterCategory,
    val enabledByDefault: Boolean,
    /** Auteur et licence de la liste, affichés dans l'application. */
    val credit: String? = null,
    val custom: Boolean = false,
)

/** Listes proposées par défaut. Toutes sont publiques, gratuites et mises à jour régulièrement. */
object FilterCatalog {
    private const val HAGEZI = "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard"
    private const val STEVENBLACK = "https://raw.githubusercontent.com/StevenBlack/hosts/master"

    val builtIn: List<FilterListInfo> = listOf(
        FilterListInfo(
            id = "adguard_dns",
            name = "AdGuard DNS filter",
            description = "Publicités et traqueurs. La liste de référence du blocage DNS, avec très peu de faux positifs.",
            urls = listOf("https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt"),
            category = FilterCategory.ADS,
            enabledByDefault = true,
            credit = "AdGuard · GPL-3.0",
        ),
        FilterListInfo(
            id = "stevenblack",
            name = "StevenBlack Unified",
            description = "Publicités et malwares : la liste « hosts » consolidée la plus utilisée.",
            urls = listOf("$STEVENBLACK/hosts"),
            category = FilterCategory.ADS,
            enabledByDefault = false,
            credit = "Steven Black · MIT",
        ),
        FilterListInfo(
            id = "hagezi_multi",
            name = "HaGeZi Multi NORMAL",
            description = "Publicités, traqueurs, mesures d'audience et télémétrie. Protection complète et équilibrée.",
            urls = listOf("$HAGEZI/multi-onlydomains.txt"),
            category = FilterCategory.TRACKERS,
            enabledByDefault = true,
            credit = "HaGeZi · GPL-3.0",
        ),
        FilterListInfo(
            id = "hagezi_pro",
            name = "HaGeZi Multi PRO",
            description = "Protection étendue et plus stricte. Peut gêner certains services.",
            urls = listOf("$HAGEZI/pro-onlydomains.txt"),
            category = FilterCategory.TRACKERS,
            enabledByDefault = false,
            credit = "HaGeZi · GPL-3.0",
        ),
        FilterListInfo(
            id = "hagezi_native",
            name = "Traqueurs des fabricants",
            description = "Télémétrie intégrée aux téléphones Samsung, Xiaomi, Huawei, Oppo/Realme et à TikTok.",
            urls = listOf(
                "$HAGEZI/native.samsung-onlydomains.txt",
                "$HAGEZI/native.xiaomi-onlydomains.txt",
                "$HAGEZI/native.huawei-onlydomains.txt",
                "$HAGEZI/native.oppo-realme-onlydomains.txt",
                "$HAGEZI/native.tiktok-onlydomains.txt",
            ),
            category = FilterCategory.TRACKERS,
            enabledByDefault = false,
            credit = "HaGeZi · GPL-3.0",
        ),
        FilterListInfo(
            id = "hagezi_tif",
            name = "Menaces (HaGeZi TIF)",
            description = "Malwares, hameçonnage, arnaques et minage de cryptomonnaie à votre insu.",
            urls = listOf("$HAGEZI/tif.mini-onlydomains.txt"),
            category = FilterCategory.SECURITY,
            enabledByDefault = true,
            credit = "HaGeZi · GPL-3.0",
        ),
        FilterListInfo(
            id = "phishing_filter",
            name = "Phishing Filter",
            description = "Sites d'hameçonnage signalés récemment.",
            urls = listOf("https://malware-filter.gitlab.io/malware-filter/phishing-filter-hosts.txt"),
            category = FilterCategory.SECURITY,
            enabledByDefault = false,
            credit = "malware-filter",
        ),
        FilterListInfo(
            id = "social",
            name = "Réseaux sociaux",
            description = "Bloque Facebook, Instagram, TikTok, X… Leurs applications cesseront de fonctionner.",
            urls = listOf("$STEVENBLACK/alternates/social-only/hosts"),
            category = FilterCategory.SOCIAL,
            enabledByDefault = false,
            credit = "Steven Black · MIT",
        ),
        FilterListInfo(
            id = "adult",
            name = "Contenu pour adultes",
            description = "Sites pornographiques.",
            urls = listOf("$STEVENBLACK/alternates/porn-only/hosts"),
            category = FilterCategory.ADULT,
            enabledByDefault = false,
            credit = "Steven Black · MIT",
        ),
        FilterListInfo(
            id = "gambling",
            name = "Jeux d'argent",
            description = "Casinos et paris en ligne.",
            urls = listOf("$STEVENBLACK/alternates/gambling-only/hosts"),
            category = FilterCategory.GAMBLING,
            enabledByDefault = false,
            credit = "Steven Black · MIT",
        ),
    )
}

/**
 * Petite liste intégrée de domaines publicitaires et de pistage très connus,
 * utilisée le temps que les vraies listes soient téléchargées (premier lancement
 * hors connexion, par exemple).
 */
object BuiltinBlocklist {
    val domains: List<String> = listOf(
        // Google
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com",
        "googletagservices.com", "2mdn.net", "admob.com", "adservice.google.com", "app-measurement.com",
        // Amazon, Microsoft, Meta, réseaux sociaux
        "amazon-adsystem.com", "bat.bing.com", "clarity.ms", "an.facebook.com", "pixel.facebook.com",
        "analytics.tiktok.com", "px.ads.linkedin.com", "static.ads-twitter.com", "analytics.twitter.com",
        "tr.snapchat.com", "ct.pinterest.com",
        // Régies et places de marché publicitaires
        "adnxs.com", "adsrvr.org", "criteo.com", "criteo.net", "taboola.com", "outbrain.com",
        "pubmatic.com", "rubiconproject.com", "openx.net", "casalemedia.com", "smartadserver.com",
        "teads.tv", "advertising.com", "adform.net", "bidswitch.net", "mathtag.com", "media.net",
        "yieldmo.com", "sharethrough.com", "moatads.com", "doubleverify.com", "adsafeprotected.com",
        "zemanta.com", "mgid.com", "revcontent.com", "propellerads.com", "popads.net", "popcash.net",
        "exoclick.com", "juicyads.com", "trafficjunky.net", "yandexadexchange.net",
        // Publicités dans les applications
        "applovin.com", "applvn.com", "unityads.unity3d.com", "inmobi.com", "chartboost.com",
        "vungle.com", "supersonicads.com", "startappservice.com", "mopub.com", "smaato.net",
        "ad.xiaomi.com", "tracking.miui.com", "samsungads.com",
        // Mesure d'audience et pistage
        "scorecardresearch.com", "quantserve.com", "hotjar.com", "mixpanel.com", "flurry.com",
        "demdex.net", "omtrdc.net", "everesttech.net", "mc.yandex.ru",
    )

    val set: HashedDomainSet by lazy { HashedDomainSet.of(domains) }
}
