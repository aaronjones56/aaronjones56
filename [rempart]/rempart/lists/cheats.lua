--[[
    Signatures de menus de triche côté client.

    Les commandes génériques ("panic", "lol"…) peuvent exister légitimement : Rempart
    ne sanctionne une commande listée ici QUE si la ressource qui l'enregistre est
    inconnue du serveur (ressource injectée) — ou si elle est enregistrée par une
    ressource serveur qui n'est pas censée la posséder (score modéré).
    Toute commande enregistrée par une ressource inconnue est de toute façon une injection.
]]

Lists = Lists or {}

Lists.CheatCommands = {
    'brutan', 'brutanpremium', 'hammafia', 'hamhaxia', 'redstonia', 'desudo', 'lynx', 'lynx9_fixed',
    'd0pamine', 'dopamine', 'dopamina', '[dopamine]', 'www.d0pamine.xyz', 'd0pamine v1.1 by nertigel',
    'tiagomodz', 'tiagomodz#1478', 'tiago', 'sovieth4x', 'jolmany', 'purgemenu', 'killmenu', 'panickey',
    'chocolate', 'maestro', 'functionok', 'hoax', 'eulen', 'eulencheats', 'skidmenu', 'fallout', 'falloutmenu',
    'luxmenu', 'hydromenu', 'kekhack', 'fivesense', 'redengine', 'absolute', 'lumia', 'ssssss', 'jailall',
    'banall', 'serverfck', 'opk',
}

-- Dictionnaires de textures chargés par des menus connus (noms distinctifs uniquement).
Lists.CheatTextures = {
    'HydroMenu', 'HydroMenuHeader', 'KentasMenu', 'KentasCheckboxDict', 'dopamine', 'Dopameme', 'dopamemes',
    'dopatest', 'hammafia', 'hoaxmenu', 'fendin', 'ISMMENUHeader', 'fivesense', 'kekhack', 'MmPremium',
    'bartowmenu', 'skidmenu', 'Urubu3', 'auttaja', 'malossimenu', 'redrum', 'godmenu', 'Absolut', 'maestro',
}
