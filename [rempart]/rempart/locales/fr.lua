Locales = Locales or {}

Locales.fr = {
    -- Connexion
    connecting = '🛡️ Rempart : vérification de votre profil…',
    banned = '\n🛡️ %s — Vous êtes banni.\n\nRaison : %s\nExpiration : %s\nIdentifiant du ban : %s\n\nContestation : %s',
    ban_evasion = 'Contournement de bannissement',
    no_license = 'Rempart : licence Rockstar introuvable. Relancez FiveM.',
    no_steam = 'Rempart : Steam doit être ouvert pour rejoindre ce serveur.',
    no_discord = 'Rempart : Discord doit être ouvert et lié à FiveM pour rejoindre ce serveur.',
    bad_name = 'Rempart : votre pseudo est invalide (%s). Modifiez-le dans les paramètres de FiveM.',
    name_too_short = 'trop court',
    name_too_long = 'trop long',
    name_html = 'caractères < > interdits',
    name_control = 'caractères invisibles',
    name_blacklist = 'terme interdit',
    reconnect_flood = 'Rempart : patientez quelques secondes avant de vous reconnecter.',
    vpn_blocked = 'Rempart : les VPN et proxys ne sont pas autorisés sur ce serveur.',

    -- Sanctions
    kicked = '🛡️ %s — Expulsé par l\'anti-cheat.\nRaison : %s',
    kick_generic = 'Comportement suspect détecté',
    ban_generic = 'Triche détectée',
    client_missing = 'Le module anti-cheat ne s\'est pas lancé. Relancez votre jeu.',
    client_timeout = 'Perte de connexion avec le module anti-cheat.',
    expires_never = 'jamais (définitif)',

    -- Notifications staff
    notify_detection = '^1[Rempart]^7 %s (#%d) : ^3%s^7 (+%s, risque %d)',
    notify_action = '^1[Rempart]^7 %s (#%d) : ^1%s^7 — %s',
    action_warn = 'AVERTISSEMENT',
    action_kick = 'EXPULSION',
    action_ban = 'BANNISSEMENT',
    action_audit = 'AUDIT (sanction non appliquée : %s)',

    -- Commandes
    cmd_no_permission = 'Permission refusée.',
    cmd_usage = 'Usage : %s',
    cmd_player_not_found = 'Joueur introuvable : %s',
    cmd_banned = 'Ban %s créé pour %s (%s).',
    cmd_unbanned = 'Ban %s levé.',
    cmd_ban_not_found = 'Aucun ban trouvé pour : %s',
    cmd_kicked = '%s expulsé.',
    cmd_audit = 'Mode audit : %s',
    cmd_exempt = 'Exemption « %s » accordée à %s pour %s.',
    cmd_reset = 'Score de %s remis à zéro.',
    cmd_screenshot = 'Capture demandée pour %s.',
    on = 'ACTIVÉ',
    off = 'DÉSACTIVÉ',
}
