--[[
    ██████╗ ███████╗███╗   ███╗██████╗  █████╗ ██████╗ ████████╗
    ██╔══██╗██╔════╝████╗ ████║██╔══██╗██╔══██╗██╔══██╗╚══██╔══╝
    ██████╔╝█████╗  ██╔████╔██║██████╔╝███████║██████╔╝   ██║
    ██╔══██╗██╔══╝  ██║╚██╔╝██║██╔═══╝ ██╔══██║██╔══██╗   ██║
    ██║  ██║███████╗██║ ╚═╝ ██║██║     ██║  ██║██║  ██║   ██║
    ╚═╝  ╚═╝╚══════╝╚═╝     ╚═╝╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝

    Configuration principale (fichier SERVEUR uniquement : jamais envoyé aux clients).

    Conseils de déploiement :
      1. Démarrez avec Config.AuditMode = true pendant 2 à 7 jours : tout est
         détecté et journalisé, AUCUNE sanction n'est appliquée.
      2. Lisez les logs (logs/*.log + Discord), ajustez les seuils / listes.
      3. Passez Config.AuditMode = false.

    Toutes les détections ont un identifiant (ex. 'explosion_blame'). Chaque
    détection peut être réglée dans Config.Detections (en bas de fichier).
]]

Config = {}

-- ═════════════════════════════════════════════════════════════════════════════
--  GÉNÉRAL
-- ═════════════════════════════════════════════════════════════════════════════

Config.Locale = 'fr'                 -- 'fr' ou 'en'
Config.AuditMode = false             -- true = observation pure, aucune sanction (recommandé au départ)
Config.Debug = false                 -- logs verbeux en console
Config.ServerName = 'Mon Serveur'    -- affiché dans les messages de ban/kick et sur Discord
Config.AppealUrl = 'discord.gg/votre-serveur'  -- où contester un ban (affiché au joueur)

-- ═════════════════════════════════════════════════════════════════════════════
--  PERMISSIONS (ACE)
--  server.cfg :
--    add_ace group.admin rempart.admin allow     # commandes + notifications staff
--    add_ace group.admin rempart.bypass allow    # immunité totale aux détections
--  Immunité ciblée : add_ace group.mod rempart.bypass.teleport allow
-- ═════════════════════════════════════════════════════════════════════════════

Config.Permissions = {
    admin = 'rempart.admin',
    bypass = 'rempart.bypass',
    bypassPrefix = 'rempart.bypass.',  -- + identifiant de détection ou de catégorie
    txAdminBypass = true,              -- admins txAdmin authentifiés = immunisés (noclip/god du menu txAdmin)
    notifyAdmins = true,               -- messages en jeu aux admins (nécessite la ressource 'chat')
    notifyMinScore = 20,               -- n'alerte pas le staff pour les détections plus faibles
}

-- ═════════════════════════════════════════════════════════════════════════════
--  SCORE DE RISQUE
--  Chaque détection ajoute des points ; le score décroît exponentiellement.
--  Les détections "certaines" (honeypot, injection, falsification…) sanctionnent
--  directement, les détections heuristiques s'accumulent : un faux positif isolé
--  ne bannit jamais personne.
-- ═════════════════════════════════════════════════════════════════════════════

Config.Risk = {
    halfLife = 600,          -- secondes : temps pour que le score soit divisé par 2
    warn = 30,               -- seuil d'alerte staff
    kick = 70,               -- seuil d'expulsion
    ban = 100,               -- seuil de bannissement
    repeatFactor = 0.5,      -- une même détection répétée dans sa fenêtre ne compte que ×0.5, ×0.25…
    rememberSeconds = 3600,  -- le score survit à une reconnexion pendant ce délai (anti "reco = reset")
    autoBanDuration = 0,     -- durée des bans automatiques en secondes (0 = définitif)
}

-- ═════════════════════════════════════════════════════════════════════════════
--  SANCTIONS
-- ═════════════════════════════════════════════════════════════════════════════

Config.Punish = {
    screenshot = true,           -- capture d'écran avant kick/ban (ressource 'screenshot-basic' requise)
    screenshotTimeout = 8000,    -- ms max d'attente de la capture
    screenshotQuality = 0.6,
    quarantine = true,           -- bloque les événements du joueur sanctionné pendant la procédure (shield)
    dropDelay = 500,             -- ms entre la décision et l'expulsion effective
}

-- ═════════════════════════════════════════════════════════════════════════════
--  BANNISSEMENTS
-- ═════════════════════════════════════════════════════════════════════════════

Config.Bans = {
    storage = 'kvp',             -- 'kvp' (intégré, sans dépendance) ou 'oxmysql' (bans partagés multi-serveurs)
    oxmysqlTable = 'rempart_bans',
    syncInterval = 60,           -- oxmysql : rechargement périodique (s) pour partager les bans entre serveurs
    identifiers = { 'license', 'license2', 'steam', 'discord', 'xbl', 'live', 'fivem' },
    useTokens = true,            -- tokens matériels (HWID) : redoutable contre les multi-comptes
    useIp = false,               -- déconseillé (IP partagées, CGNAT)
    extendOnEvasion = true,      -- contournement détecté => les nouveaux identifiants rejoignent le ban
    idPrefix = 'RMP',
}

-- ═════════════════════════════════════════════════════════════════════════════
--  CONNEXION
-- ═════════════════════════════════════════════════════════════════════════════

Config.Connection = {
    enabled = true,
    requireLicense = true,
    requireSteam = false,
    requireDiscord = false,
    reconnectCooldown = 5,       -- s minimum entre deux connexions d'un même compte (anti-flood)
    name = {
        enabled = true,
        minLength = 2,
        maxLength = 32,
        blockHtml = true,        -- '<', '>' : injections HTML dans les UI (chat, scoreboard…)
        blockControl = true,     -- caractères invisibles/de contrôle
        blacklist = {},          -- sous-chaînes interdites (insensible à la casse), ex. { 'discord.gg' }
    },
    vpn = {
        enabled = false,         -- vérification VPN/proxy via proxycheck.io
        apiKey = '',             -- facultatif (quota plus élevé) — préférez la convar rempart_proxycheck_key
        allowOnError = true,     -- si l'API ne répond pas : laisser entrer
        whitelist = {},          -- identifiants autorisés malgré un VPN
    },
}

-- ═════════════════════════════════════════════════════════════════════════════
--  JOURNALISATION
--  Les URL de webhooks sont de préférence définies par convars (plus sûr) :
--     set rempart_webhook_detections "https://discord.com/api/webhooks/..."
--     set rempart_webhook_bans       "https://discord.com/api/webhooks/..."
--     set rempart_webhook_admin      "https://discord.com/api/webhooks/..."
--     set rempart_webhook_system     "https://discord.com/api/webhooks/..."
--  et protégées contre la lecture par les autres ressources (backdoors !) :
--     add_convar_permission rempart read rempart_webhook_detections
--     (idem pour chaque convar)
-- ═════════════════════════════════════════════════════════════════════════════

Config.Logs = {
    console = true,
    file = true,                 -- logs/AAAA-MM-JJ.log (une ligne JSON par événement)
    discord = {
        enabled = true,
        username = 'Rempart',
        avatar = '',
        webhooks = { detections = '', bans = '', admin = '', system = '' },
        minScore = 10,           -- ignore les détections plus faibles (les sanctions sont toujours envoyées)
        mentionOnBan = '',       -- ex. '<@&123456789>' pour notifier un rôle
    },
}

-- ═════════════════════════════════════════════════════════════════════════════
--  CLIENT ANTI-CHEAT (heartbeat signé HMAC-SHA256 + détections côté client)
-- ═════════════════════════════════════════════════════════════════════════════

Config.Client = {
    enabled = true,
    helloTimeout = 300,          -- s : délai max pour que le module client démarre après la connexion
    heartbeatInterval = 15,      -- s entre deux défis
    maxMissed = 4,               -- défis consécutifs sans réponse valide => kick (pas de ban : connexions instables)
    checks = {
        resources = true,        -- ressources injectées / arrêtées localement
        commands = true,         -- commandes enregistrées par des menus de triche
        textures = true,         -- textures de menus connus
        godmode = true,
        spectate = true,
        invisible = true,
        noclip = true,
        freecam = true,
        vision = false,          -- vision nocturne/thermique non déclarée (désactivé : jobs police/hélico)
        weapons = true,
        vehicles = true,
        tinyPed = true,
        ragdoll = false,         -- anti-ragdoll (désactivé : certains serveurs le coupent volontairement)
        devtools = true,         -- DevTools NUI (piège 'debugger')
    },
    freecamDistance = 120.0,     -- m entre caméra et joueur
    noclipHeight = 8.0,          -- m au-dessus du sol sans chute
    vehicleSpeedFactor = 1.6,    -- vitesse max estimée du modèle × facteur (+15 m/s de marge)
}

-- ═════════════════════════════════════════════════════════════════════════════
--  ENTITÉS (entityCreating) — 100 % serveur
-- ═════════════════════════════════════════════════════════════════════════════

Config.Entities = {
    enabled = true,
    -- Limites de spawn par joueur (seau à jetons : rafale max / recharge par seconde)
    limits = {
        vehicle = { burst = 8, rate = 0.5 },
        ped     = { burst = 10, rate = 0.5 },
        object  = { burst = 80, rate = 4.0 },   -- généreux : meubles/décors en rafale
    },
    -- Entité créée par un script qui n'existe pas côté serveur => exécuteur/injection.
    unknownScript = true,
    -- Ressources qui ne doivent JAMAIS créer d'entités (cibles favorites des exécuteurs Lua).
    noSpawnResources = {
        'chat', 'spawnmanager', 'sessionmanager', 'mapmanager', 'hardcap', 'baseevents', 'rconlog',
        'basic-gamemode', 'fivem-map-skater', 'fivem-map-hipster', 'yarn', 'webpack', 'oxmysql',
        'screenshot-basic', 'pma-voice', 'mumble-voip', 'tokovoip_script',
    },
    -- Modèles de ped/véhicule "joueur" toujours autorisés (exceptions).
    allowModels = {},
    -- Objets attachés à un AUTRE joueur (cages, props « troll »).
    attachToPlayers = true,
    attachAllowModels = {},      -- ex. sacs, menottes… si un script légitime en attache à autrui
}

-- ═════════════════════════════════════════════════════════════════════════════
--  EXPLOSIONS (explosionEvent) — 100 % serveur
-- ═════════════════════════════════════════════════════════════════════════════

Config.Explosions = {
    enabled = true,
    allowMilitary = false,       -- autorise les explosions militaires/DLC (canon orbital, bombes, mines…)
    maxPerWindow = 12,           -- explosions max par joueur…
    window = 10,                 -- …sur cette fenêtre (s)
    remoteDistance = 400.0,      -- explosion à plus de X m du joueur qui la crée
    nearVictimDistance = 4.0,    -- explosion "posée" sur un autre joueur
    blockInvisible = true,       -- explosions invisibles avec dégâts
    blockSilent = false,         -- explosions inaudibles (certains scripts en utilisent)
    maxDamageScale = 1.5,
    maxCameraShake = 5.0,
    blockTypes = {},             -- types supplémentaires à bloquer (ids, voir lists/explosions.lua)
    allowTypes = {},             -- types à autoriser malgré la liste par défaut
}

-- ═════════════════════════════════════════════════════════════════════════════
--  ARMES & COMBAT (giveWeaponEvent, weaponDamageEvent…) — 100 % serveur
-- ═════════════════════════════════════════════════════════════════════════════

Config.Weapons = {
    enabled = true,
    -- Armes interdites en main (vérification serveur périodique + client)
    blacklist = {
        'WEAPON_RAILGUN', 'WEAPON_RAILGUNXM3', 'WEAPON_RAYPISTOL', 'WEAPON_RAYCARBINE', 'WEAPON_RAYMINIGUN',
        'WEAPON_MINIGUN', 'WEAPON_EMPLAUNCHER', 'WEAPON_HOMINGLAUNCHER', 'WEAPON_COMPACTLAUNCHER',
        'WEAPON_GRENADELAUNCHER', 'WEAPON_RPG',   -- retirez WEAPON_RPG si votre serveur l'autorise
    },
    removeBlacklisted = true,    -- retire l'arme côté serveur
    checkInterval = 2000,        -- ms
    -- Un client ne doit jamais donner/retirer d'arme au ped d'un AUTRE joueur.
    blockGiveToPlayers = true,
    blockRemoveFromPlayers = true,
}

Config.Combat = {
    enabled = true,
    cancelImpossible = true,     -- annule les dégâts impossibles (distance, bucket, arme interdite)
    rangeMultiplier = 1.0,       -- multiplie les portées max de lists/weapons.lua
    angleCheck = true,           -- tir "dans le dos" (silent aim) : angle cap du tireur / cible
    maxAngle = 115.0,            -- degrés
    angleMinDistance = 6.0,      -- ignoré à bout portant
    rateCheck = true,            -- cadence impossible
    multiTarget = 6,             -- cibles distinctes touchées en 2 s (kill aura)
    maxOverrideDamage = 300,     -- dégâts forcés max (overrideDefaultDamage) sur un joueur
}

-- ═════════════════════════════════════════════════════════════════════════════
--  EFFETS : particules, feux, projectiles — 100 % serveur
-- ═════════════════════════════════════════════════════════════════════════════

Config.Effects = {
    ptfx = {
        enabled = true,
        maxPerWindow = 25, window = 5,
        maxScale = 5.0,
        remoteDistance = 300.0,
        blacklist = {            -- effets (noms ou hashes) interdits
            'scr_xm_orbital_blast', 'scr_xm_orbital', 'exp_grd_rpg_lod',
        },
        blacklistAssets = { 'scr_xm_orbital', 'scr_rcbarry2' },
    },
    fire = {
        enabled = true,
        maxPerWindow = 20, window = 10,
        remoteDistance = 300.0,
        onPlayers = true,        -- feu attaché à un autre joueur sans arme
    },
    projectiles = {
        enabled = true,
        maxPerWindow = 40, window = 5,
        maxSpawnDistance = 25.0, -- projectile qui naît loin du tireur (magic bullet)
        singleBulletScore = true,-- ShootSingleBulletBetweenCoords hors arme en main
    },
}

-- ═════════════════════════════════════════════════════════════════════════════
--  TÂCHES FORCÉES (clearPedTasksEvent, givePedScriptedTaskEvent)
-- ═════════════════════════════════════════════════════════════════════════════

Config.Tasks = {
    enabled = true,
    blockClearOnPlayers = true,  -- éjection de véhicule / gel de joueurs
    blockScriptedOnPlayers = true,
}

-- ═════════════════════════════════════════════════════════════════════════════
--  MOUVEMENT (serveur) : téléportation, vitesse, noclip
-- ═════════════════════════════════════════════════════════════════════════════

Config.Movement = {
    enabled = true,
    interval = 1000,             -- ms entre deux échantillons
    spawnGrace = 45,             -- s d'immunité après connexion/réapparition/changement de ped
    teleport = {
        enabled = true,
        footDistance = 45.0,     -- m parcourus en 1 s à pied
        vehicleDistance = 160.0, -- m en 1 s en véhicule terrestre
        airDistance = 300.0,     -- m en 1 s en avion/hélico
        learnPoints = true,      -- apprend les points de téléportation légitimes (ascenseurs, intérieurs…)
        learnPlayers = 3,        -- joueurs distincts requis pour valider un point
        learnRadius = 15.0,
    },
    speed = {
        enabled = true,
        footSpeed = 14.0,        -- m/s à pied (sprint ≈ 7-8 m/s)
        samples = 3,             -- échantillons consécutifs requis
    },
    noclip = {
        enabled = true,
        minSpeed = 3.0,          -- m/s : n'évalue que les joueurs en mouvement
    },
}

-- ═════════════════════════════════════════════════════════════════════════════
--  ÉTAT DU JOUEUR (serveur) : godmode, super saut, modificateurs, santé…
-- ═════════════════════════════════════════════════════════════════════════════

Config.PlayerState = {
    enabled = true,
    interval = 2500,             -- ms
    godmode = true,              -- GetPlayerInvincible (lu depuis la synchro OneSync)
    superJump = true,
    maxWeaponDamageModifier = 1.0,   -- valeurs > seuil = cheat (les serveurs qui réduisent les dégâts restent OK)
    maxMeleeDamageModifier = 1.0,
    minWeaponDefenseModifier = 0.98, -- hors plage [min,max] = suspect
    maxWeaponDefenseModifier = 1.02,
    maxHealth = 200,
    maxArmour = 100,
    invisible = true,
    collision = true,
    frozenMoving = true,
    freecamDistance = 250.0,     -- focus caméra serveur (GetPlayerFocusPos) éloigné du ped
    airDrag = true,
    blacklistedPeds = {          -- modèles de joueur interdits (oiseaux = vol, animaux marins…)
        'a_c_seagull', 'a_c_crow', 'a_c_chickenhawk', 'a_c_cormorant', 'a_c_pigeon',
        'a_c_killerwhale', 'a_c_humpback', 'a_c_dolphin', 'a_c_sharkhammer', 'a_c_sharktiger', 'a_c_stingray',
    },
}

-- ═════════════════════════════════════════════════════════════════════════════
--  VÉHICULES (serveur)
-- ═════════════════════════════════════════════════════════════════════════════

Config.Vehicles = {
    enabled = true,
    interval = 3000,
    maxEngineHealth = 1000.0,
    maxBodyHealth = 1000.0,
    repairCheck = true,          -- réparation client non déclarée (compteur GetVehicleTotalRepairs)
}

-- ═════════════════════════════════════════════════════════════════════════════
--  ÉVÉNEMENTS RÉSEAU : pare-feu, pièges (honeypots), capteur global
-- ═════════════════════════════════════════════════════════════════════════════

Config.Events = {
    honeypots = true,            -- événements-pièges (désarmés automatiquement s'ils existent sur le serveur)
    extraHoneypots = {},         -- vos propres pièges
    disabledHoneypots = {},      -- pièges à ne jamais armer
    staticScan = true,           -- recense les événements réseau réels du serveur (analyse des scripts)
    sensor = {                   -- nécessite la ressource rempart_sensor
        floodPerSecond = 35,     -- événements/s soutenus sur 5 s
        burstDistinct = 40,      -- noms d'événements distincts en 5 s (menus "trigger all")
        maxPayload = 262144,     -- octets pour un seul événement
        unknownScore = true,     -- événements inexistants
        joinGrace = 90,          -- s : chargement initial (nombreux événements légitimes)
    },
    -- Pare-feu déclaratif (appliqué par le shield dans les ressources protégées).
    firewall = {
        defaultRate = 25,        -- appels/s par événement et par joueur…
        defaultBurst = 60,       -- …avec cette rafale
        maxString = 65536,       -- octets par chaîne d'argument
        maxDepth = 12,
        maxNodes = 8192,
        maxNumber = 1e12,
        rules = {
            -- ['esx_garbagejob:pay'] = { rate = 1, per = 60 },
            -- ['bank:withdraw'] = { rate = 3, per = 10, near = { vector3(150.0, -1040.0, 29.0) }, radius = 30.0 },
            -- ['admin:setJob'] = { serverOnly = true },          -- jamais déclenchable par un client
            -- ['police:cuff'] = { ace = 'job.police' },          -- réservé à un principal ACE
        },
    },
}

-- ═════════════════════════════════════════════════════════════════════════════
--  AUDIT DE SÉCURITÉ & SCANNER DE BACKDOORS
-- ═════════════════════════════════════════════════════════════════════════════

Config.Audit = {
    onStart = true,              -- rapport de sécurité au démarrage (convars, ACL, nom de ressource…)
    autoHarden = false,          -- applique automatiquement les convars sûres modifiables à chaud
}

Config.Scanner = {
    onStart = true,              -- analyse toutes les ressources à la recherche de backdoors (Cipher…)
    maxFileSize = 2 * 1024 * 1024,
    ignoreResources = {},
}

-- ═════════════════════════════════════════════════════════════════════════════
--  RÉGLAGE FIN DES DÉTECTIONS
--  Champs : enabled (bool), action ('score' | 'kick' | 'ban' | 'log'), score (nombre),
--           cooldown (s), banDuration (s, 0 = définitif), screenshot (bool).
--  Liste complète et valeurs par défaut : server/core/catalog.lua
-- ═════════════════════════════════════════════════════════════════════════════

Config.Detections = {
    -- ['teleport'] = { enabled = false },
    -- ['explosion_blame'] = { action = 'ban' },
    -- ['freecam'] = { score = 0, action = 'log' },
}
