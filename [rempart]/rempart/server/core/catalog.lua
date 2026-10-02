--[[
    Catalogue des détections (valeurs par défaut).

    action :
      'score'  ajoute `score` au risque du joueur ; les seuils (Config.Risk) décident
      'kick'   expulsion immédiate (+ score)
      'ban'    bannissement immédiat
      'log'    journalisation uniquement
    cooldown : fenêtre (s) pendant laquelle une répétition compte moins (Config.Risk.repeatFactor)

    Philosophie : 'ban' immédiat UNIQUEMENT pour les preuves non ambiguës
    (piège déclenché, ressource injectée, réponse cryptographique falsifiée,
    arme donnée à autrui…). Tout le reste est cumulatif.
]]

Catalog = {
    -- ── Entités ─────────────────────────────────────────────────────────────
    entity_blacklisted      = { category = 'entity', score = 50, action = 'score', cooldown = 30,
        fr = 'Spawn d\'un modèle interdit', en = 'Blacklisted model spawn' },
    entity_spam             = { category = 'entity', score = 35, action = 'score', cooldown = 20,
        fr = 'Spawn massif d\'entités', en = 'Entity spam' },
    entity_unknown_script   = { category = 'entity', score = 100, action = 'score', cooldown = 30, screenshot = true,
        fr = 'Entité créée par un script inconnu (exécuteur)', en = 'Entity created by an unknown script (executor)' },
    entity_forbidden_res    = { category = 'entity', score = 80, action = 'score', cooldown = 30, screenshot = true,
        fr = 'Entité créée depuis une ressource détournée', en = 'Entity created from a hijacked resource' },
    entity_attach_player    = { category = 'entity', score = 40, action = 'score', cooldown = 15,
        fr = 'Objet attaché à un autre joueur', en = 'Object attached to another player' },

    -- ── Explosions ─────────────────────────────────────────────────────────
    explosion_blocked       = { category = 'explosion', score = 40, action = 'score', cooldown = 10,
        fr = 'Explosion d\'un type interdit', en = 'Forbidden explosion type' },
    explosion_spam          = { category = 'explosion', score = 35, action = 'score', cooldown = 15,
        fr = 'Spam d\'explosions', en = 'Explosion spam' },
    explosion_blame         = { category = 'explosion', score = 60, action = 'score', cooldown = 30, screenshot = true,
        fr = 'Explosion attribuée à un autre joueur', en = 'Explosion blamed on another player' },
    explosion_remote        = { category = 'explosion', score = 30, action = 'score', cooldown = 15,
        fr = 'Explosion à distance sur un joueur', en = 'Remote explosion on a player' },
    explosion_modified      = { category = 'explosion', score = 25, action = 'score', cooldown = 15,
        fr = 'Explosion invisible/silencieuse/amplifiée', en = 'Invisible/silent/boosted explosion' },

    -- ── Armes ──────────────────────────────────────────────────────────────
    weapon_give_player      = { category = 'weapon', score = 100, action = 'ban', cooldown = 30, screenshot = true,
        fr = 'Arme donnée à un autre joueur', en = 'Weapon given to another player' },
    weapon_remove_player    = { category = 'weapon', score = 100, action = 'ban', cooldown = 30, screenshot = true,
        fr = 'Arme retirée à un autre joueur', en = 'Weapon removed from another player' },
    weapon_blacklisted      = { category = 'weapon', score = 60, action = 'score', cooldown = 30, screenshot = true,
        fr = 'Arme interdite en main', en = 'Blacklisted weapon in hand' },

    -- ── Combat ─────────────────────────────────────────────────────────────
    combat_distance         = { category = 'combat', score = 25, action = 'score', cooldown = 10,
        fr = 'Dégâts à une distance impossible', en = 'Damage from an impossible distance' },
    combat_angle            = { category = 'combat', score = 12, action = 'score', cooldown = 5,
        fr = 'Tir dans un angle impossible (silent aim)', en = 'Impossible shot angle (silent aim)' },
    combat_rate             = { category = 'combat', score = 35, action = 'score', cooldown = 10,
        fr = 'Cadence de tir impossible', en = 'Impossible fire rate' },
    combat_multitarget      = { category = 'combat', score = 45, action = 'score', cooldown = 15, screenshot = true,
        fr = 'Touches simultanées sur de nombreuses cibles (kill aura)', en = 'Many targets hit at once (kill aura)' },
    combat_bucket           = { category = 'combat', score = 50, action = 'score', cooldown = 15,
        fr = 'Dégâts à travers les dimensions', en = 'Damage across routing buckets' },
    combat_override         = { category = 'combat', score = 40, action = 'score', cooldown = 15,
        fr = 'Dégâts forcés anormaux', en = 'Abnormal forced damage' },
    combat_blacklisted      = { category = 'combat', score = 50, action = 'score', cooldown = 15,
        fr = 'Dégâts avec une arme interdite', en = 'Damage with a blacklisted weapon' },

    -- ── Effets ─────────────────────────────────────────────────────────────
    ptfx_spam               = { category = 'effect', score = 30, action = 'score', cooldown = 15,
        fr = 'Spam de particules', en = 'Particle spam' },
    ptfx_blocked            = { category = 'effect', score = 40, action = 'score', cooldown = 15,
        fr = 'Particule interdite ou géante', en = 'Forbidden or giant particle' },
    fire_spam               = { category = 'effect', score = 30, action = 'score', cooldown = 15,
        fr = 'Spam de feux', en = 'Fire spam' },
    fire_player             = { category = 'effect', score = 40, action = 'score', cooldown = 15,
        fr = 'Feu allumé sur un autre joueur', en = 'Fire started on another player' },
    projectile_spawn        = { category = 'effect', score = 35, action = 'score', cooldown = 10,
        fr = 'Projectile créé hors de toute arme (magic bullet)', en = 'Projectile spawned without a weapon (magic bullet)' },
    projectile_spam         = { category = 'effect', score = 35, action = 'score', cooldown = 15,
        fr = 'Spam de projectiles', en = 'Projectile spam' },

    -- ── Tâches ─────────────────────────────────────────────────────────────
    task_clear_player       = { category = 'task', score = 50, action = 'score', cooldown = 10,
        fr = 'Tâches d\'un autre joueur annulées (éjection/gel)', en = 'Another player\'s tasks cleared' },
    task_force_player       = { category = 'task', score = 60, action = 'score', cooldown = 10,
        fr = 'Tâche imposée à un autre joueur', en = 'Task forced on another player' },

    -- ── Mouvement ──────────────────────────────────────────────────────────
    teleport                = { category = 'movement', score = 15, action = 'score', cooldown = 20,
        fr = 'Téléportation non déclarée', en = 'Undeclared teleport' },
    speedhack               = { category = 'movement', score = 30, action = 'score', cooldown = 20,
        fr = 'Vitesse à pied impossible', en = 'Impossible on-foot speed' },
    noclip                  = { category = 'movement', score = 40, action = 'score', cooldown = 15,
        fr = 'Noclip (déplacement sans collision)', en = 'Noclip' },

    -- ── État du joueur ─────────────────────────────────────────────────────
    godmode                 = { category = 'state', score = 35, action = 'score', cooldown = 15,
        fr = 'Invincibilité (godmode)', en = 'Godmode' },
    superjump               = { category = 'state', score = 50, action = 'score', cooldown = 20,
        fr = 'Super saut', en = 'Super jump' },
    damage_modifier         = { category = 'state', score = 100, action = 'score', cooldown = 30, screenshot = true,
        fr = 'Modificateur de dégâts', en = 'Damage modifier' },
    defense_modifier        = { category = 'state', score = 50, action = 'score', cooldown = 30,
        fr = 'Modificateur de défense', en = 'Defense modifier' },
    health_overflow         = { category = 'state', score = 50, action = 'score', cooldown = 20,
        fr = 'Santé ou armure au-delà du maximum', en = 'Health or armour above maximum' },
    invisible               = { category = 'state', score = 30, action = 'score', cooldown = 15,
        fr = 'Invisibilité en mouvement', en = 'Invisible while moving' },
    freecam                 = { category = 'state', score = 8, action = 'score', cooldown = 30,
        fr = 'Caméra libre éloignée', en = 'Detached free camera' },
    ped_blacklisted         = { category = 'state', score = 50, action = 'score', cooldown = 30,
        fr = 'Modèle de personnage interdit', en = 'Blacklisted player model' },
    air_drag                = { category = 'state', score = 30, action = 'score', cooldown = 30,
        fr = 'Traînée aérodynamique modifiée (boost véhicule)', en = 'Modified air drag (vehicle boost)' },

    -- ── Véhicules ──────────────────────────────────────────────────────────
    vehicle_health          = { category = 'vehicle', score = 30, action = 'score', cooldown = 30,
        fr = 'Santé de véhicule au-delà du maximum', en = 'Vehicle health above maximum' },
    vehicle_repair          = { category = 'vehicle', score = 5, action = 'score', cooldown = 60,
        fr = 'Réparation de véhicule non déclarée', en = 'Undeclared vehicle repair' },

    -- ── Événements réseau ──────────────────────────────────────────────────
    event_honeypot          = { category = 'event', score = 100, action = 'ban', cooldown = 0, screenshot = true,
        fr = 'Événement-piège déclenché', en = 'Honeypot event triggered' },
    event_unknown           = { category = 'event', score = 3, action = 'score', cooldown = 30,
        fr = 'Événements inexistants déclenchés', en = 'Non-existent events triggered' },
    event_burst             = { category = 'event', score = 35, action = 'score', cooldown = 30,
        fr = 'Rafale d\'événements distincts (trigger all)', en = 'Burst of distinct events (trigger all)' },
    event_flood             = { category = 'event', score = 40, action = 'score', cooldown = 30,
        fr = 'Flood d\'événements réseau', en = 'Network event flood' },
    event_payload           = { category = 'event', score = 25, action = 'score', cooldown = 30,
        fr = 'Événement réseau démesuré', en = 'Oversized network event' },
    event_firewall          = { category = 'event', score = 20, action = 'score', cooldown = 10,
        fr = 'Règle du pare-feu d\'événements violée', en = 'Event firewall rule violated' },
    event_malformed         = { category = 'event', score = 30, action = 'score', cooldown = 10,
        fr = 'Arguments d\'événement malformés', en = 'Malformed event arguments' },

    -- ── Client anti-cheat ──────────────────────────────────────────────────
    client_missing          = { category = 'client', score = 0, action = 'kick', cooldown = 0,
        fr = 'Module anti-cheat client absent', en = 'Client anti-cheat module missing' },
    heartbeat_timeout       = { category = 'client', score = 20, action = 'kick', cooldown = 0,
        fr = 'Module anti-cheat client interrompu', en = 'Client anti-cheat module stopped' },
    heartbeat_tamper        = { category = 'client', score = 100, action = 'ban', cooldown = 0, screenshot = true,
        fr = 'Réponse anti-cheat falsifiée', en = 'Forged anti-cheat response' },
    resource_injected       = { category = 'client', score = 100, action = 'ban', cooldown = 0, screenshot = true,
        fr = 'Ressource injectée côté client (exécuteur)', en = 'Client-side injected resource (executor)' },
    resource_stopped        = { category = 'client', score = 100, action = 'ban', cooldown = 0, screenshot = true,
        fr = 'Ressource arrêtée côté client (resource stopper)', en = 'Resource stopped client-side (resource stopper)' },
    command_injected        = { category = 'client', score = 60, action = 'score', cooldown = 60, screenshot = true,
        fr = 'Commande de menu de triche', en = 'Cheat menu command' },
    texture_menu            = { category = 'client', score = 80, action = 'score', cooldown = 60, screenshot = true,
        fr = 'Texture de menu de triche chargée', en = 'Cheat menu texture loaded' },
    nui_devtools            = { category = 'client', score = 50, action = 'score', cooldown = 60,
        fr = 'Outils de développement NUI ouverts', en = 'NUI devtools opened' },
    client_godmode          = { category = 'client', score = 35, action = 'score', cooldown = 20,
        fr = 'Invincibilité (client)', en = 'Godmode (client)' },
    client_spectate         = { category = 'client', score = 30, action = 'score', cooldown = 30,
        fr = 'Mode spectateur non autorisé', en = 'Unauthorised spectator mode' },
    client_invisible        = { category = 'client', score = 25, action = 'score', cooldown = 20,
        fr = 'Invisibilité (client)', en = 'Invisibility (client)' },
    client_noclip           = { category = 'client', score = 35, action = 'score', cooldown = 15,
        fr = 'Noclip / vol (client)', en = 'Noclip / flying (client)' },
    client_freecam          = { category = 'client', score = 10, action = 'score', cooldown = 30,
        fr = 'Caméra libre (client)', en = 'Free camera (client)' },
    client_vision           = { category = 'client', score = 15, action = 'score', cooldown = 60,
        fr = 'Vision nocturne/thermique non déclarée', en = 'Undeclared night/thermal vision' },
    client_weapon           = { category = 'client', score = 40, action = 'score', cooldown = 20,
        fr = 'Arme ou modificateur d\'arme interdit (client)', en = 'Forbidden weapon or weapon modifier (client)' },
    client_vehicle          = { category = 'client', score = 30, action = 'score', cooldown = 30,
        fr = 'Véhicule modifié (godmode/boost/vitesse)', en = 'Modified vehicle (godmode/boost/speed)' },
    client_tiny_ped         = { category = 'client', score = 40, action = 'score', cooldown = 60,
        fr = 'Personnage miniature (hitbox réduite)', en = 'Tiny ped (reduced hitbox)' },
    client_ragdoll          = { category = 'client', score = 10, action = 'score', cooldown = 60,
        fr = 'Anti-ragdoll non déclaré', en = 'Undeclared anti-ragdoll' },
    witness_stop            = { category = 'client', score = 30, action = 'score', cooldown = 30,
        fr = 'Arrêt de l\'anti-cheat signalé par une autre ressource', en = 'Anti-cheat stop reported by another resource' },

    -- ── Connexion ──────────────────────────────────────────────────────────
    ban_evasion             = { category = 'connection', score = 100, action = 'ban', cooldown = 0,
        fr = 'Contournement de bannissement', en = 'Ban evasion' },

    -- ── Externe (exports) ──────────────────────────────────────────────────
    custom                  = { category = 'custom', score = 25, action = 'score', cooldown = 10,
        fr = 'Détection externe', en = 'External detection' },
}

return Catalog
