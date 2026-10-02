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
    'banall', 'serverfck', 'opk', 'hyra',
}

-- Dictionnaires de textures chargés par des menus connus (noms distinctifs uniquement).
Lists.CheatTextures = {
    'HydroMenu', 'HydroMenuHeader', 'KentasMenu', 'KentasCheckboxDict', 'dopamine', 'Dopameme', 'dopamemes',
    'dopatest', 'hammafia', 'hoaxmenu', 'fendin', 'ISMMENUHeader', 'fivesense', 'kekhack', 'MmPremium',
    'bartowmenu', 'skidmenu', 'Urubu3', 'auttaja', 'malossimenu', 'redrum', 'godmenu', 'Absolut', 'maestro',
}

-- Textures d'exécution (DUI) créées par des menus Lua : paire { dictionnaire, texture }.
-- GetTextureResolution renvoie 4×4 pour une texture absente : toute autre valeur = menu chargé.
-- Paires distinctives uniquement (sources : anticheese-anticheat, SecureServe).
Lists.CheatRuntimeTextures = {
    { 'dopatest', 'duiTex', 'Copypaste' }, { 'fm', 'menu_bg', 'Fallout' }, { 'meow2', 'woof2', 'Alokas66' },
    { 'adb831a7fdd83d_Guest_d1e2a309ce7591dff86', 'adb831a7fdd83d_Guest_d1e2a309ce7591dff8Header6', 'Guest' },
    { 'hugev_gif_DSGUHSDGISDG', 'duiTex_DSIOGJSDG', 'HugeV' }, { 'absoluteeulen', 'Absolut', 'Absolute' },
    { 'Dopamine', 'Dopameme', 'Dopamine' }, { 'SkidMenu', 'skidmenu', 'Skid' }, { 'tiago', 'Tiago', 'Tiago' },
    { 'lynxmenu', 'lynxmenu', 'Lynx' }, { 'HydroMenu', 'HydroMenuHeader', 'Hydro' },
    { 'KentasMenu', 'KentasCheckboxDict', 'Kentas' },
}

-- Variables globales définies par des menus Lua injectés (exécuteurs). Seuls les noms
-- distinctifs sont gardés : « WarMenu », « Plane », « Ham »… existent dans des scripts légitimes.
-- Sources : Badger-Anticheat / Valkyrie, SecureServe.
Lists.CheatGlobals = {
    'AlikhanCheats', 'gaybuild', 'LynxEvo', 'FendinX', 'FendinXMenu', 'Lynx8', 'LynxSeven', 'LynxRevo',
    'lynxunknowncheats', 'MIOddhwuie', 'ililililil', 'esxdestroyv2', 'LiLLL', 'HamMafia', 'HamHaxia',
    'Absolute_function', 'TiagoMenu', 'SkazaMenu', 'FlexSkazaMenu', 'BrutanPremium', 'b00mMenu', 'b00mek', 'Cience',
    'MaestroMenu', 'MaestroEra', 'NertigelFunc', 'dreanhsMod', 'nukeserver', 'SDefwsWr', 'DynnoFamily',
    'FrostedMenu', 'frosted_config', 'CKgang', 'HoaxMenu', 'alkomenu', 'xseira', 'KoGuSzEk', 'ariesMenu',
    'Outcasts666', 'redMENU', 'xnsadifnias', 'LDOWJDWDdddwdwdad', 'moneymany', 'VOITUREMenu', 'fESX', 'dexMenu',
    'AKTeam', 'SwagMenu', 'SwagUI', 'Dopameme', 'Dopamine', 'nigmenu0001', 'FantaMenuEvo', 'GRubyMenu',
    'AlphaVeta', 'ShaniuMenu', 'NyPremium', 'lIlIllIlI', 'IlIlIlIlIlI', 'qJtbGTz5y8ZmqcAg', 'LuxUI', 'JokerMenu',
    'SidMenu', 'GheMenu', 'jailServerLoop', 'carSpamServer', 'nofuckinglol', 'Wugr4yfgb', 'rootMenuv2',
    'rootMenuv3', 'HydroMenu', 'KentasMenu',
}

-- Événements CLIENT que les menus déclenchent localement (TriggerEvent) pour exploiter des
-- scripts ou sonder le framework. Armés uniquement si la ressource `res` n'existe PAS sur
-- ce serveur (sinon ce sont des événements légitimes). res = préfixe de l'événement par défaut.
Lists.ClientHoneypots = {
    { 'esx:getSharedObject', res = 'es_extended', score = 30 },   -- sondage ESX sur un serveur sans ESX
    { 'esx:spawnVehicle', res = 'es_extended' },
    { 'QBCore:GetObject', res = 'qb-core', score = 30 },          -- sondage QBCore sur un serveur sans QBCore
    { 'esx_ambulancejob:revive' }, { 'ambulancier:selfRespawn' }, { 'esx-qalle-jail:openJailMenu' },
    { 'esx_jailer:wysylandoo' }, { 'esx_policejob:getarrested' }, { 'esx_society:openBossMenu' },
    { 'esx_status:set' }, { 'HCheat:TempDisableDetection', score = 80 },
}
