--[[
    Rempart — amorçage du serveur : espace de noms, locales, catalogue fusionné,
    registre de modules, constantes réseau.
]]

local RES = GetCurrentResourceName()

Rempart = {
    version = '1.0.0',
    res = RES,
    -- Événements du canal sécurisé (dérivés du nom de ressource : renommer la ressource les change).
    EV_C2S = RES .. ':c',
    EV_S2C = RES .. ':s',
    -- Événements serveur-locaux (jamais enregistrés comme événements réseau).
    EV_SHIELD = RES .. ':shield',
    EV_SENSOR = RES .. ':sensor',
    modules = {},
    ready = false,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Locales
-- ─────────────────────────────────────────────────────────────────────────────

local lang = (Locales and Locales[Config.Locale]) or Locales.fr

function L(key, ...)
    local s = lang[key] or Locales.fr[key] or key
    if select('#', ...) > 0 then
        local ok, out = pcall(string.format, s, ...)
        return ok and out or s
    end
    return s
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Temps
-- ─────────────────────────────────────────────────────────────────────────────

--- Horloge monotone en millisecondes.
function Rempart.now()
    return GetGameTimer()
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Catalogue des détections fusionné avec la configuration
-- ─────────────────────────────────────────────────────────────────────────────

Rempart.Detections = {}

for id, def in pairs(Catalog) do
    local d = Utils.deepCopy(def)
    d.id = id
    d.enabled = d.enabled ~= false
    Rempart.Detections[id] = d
end

local unknownOverrides = {}
for id, over in pairs(Config.Detections or {}) do
    local d = Rempart.Detections[id]
    if d then
        for k, v in pairs(over) do d[k] = v end
    else
        unknownOverrides[#unknownOverrides + 1] = id
    end
end

--- Libellé localisé d'une détection.
function Rempart.label(id)
    local d = Rempart.Detections[id]
    if not d then return tostring(id) end
    return d[Config.Locale] or d.fr or id
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Webhooks : convars prioritaires sur la configuration
-- ─────────────────────────────────────────────────────────────────────────────

Rempart.webhooks = {}
for _, channel in ipairs({ 'detections', 'bans', 'admin', 'system' }) do
    local fromConvar = GetConvar('rempart_webhook_' .. channel, '')
    local fromConfig = Config.Logs.discord.webhooks[channel] or ''
    Rempart.webhooks[channel] = (fromConvar ~= '' and fromConvar) or fromConfig
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Registre de modules
-- ─────────────────────────────────────────────────────────────────────────────

Rempart.modulesByName = {}

--- Déclare un module. `mod.init()` est appelé au démarrage (protégé par pcall).
function Rempart.module(name, mod)
    mod.name = name
    Rempart.modules[#Rempart.modules + 1] = mod
    Rempart.modulesByName[name] = mod
    return mod
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Tables de correspondance pré-calculées (hashes normalisés 32 bits)
-- ─────────────────────────────────────────────────────────────────────────────

Rempart.lookup = {
    weaponBlacklist = Utils.hashSet(Config.Weapons.blacklist),
    pedBlacklist = Utils.hashSet(Config.PlayerState.blacklistedPeds),
    objectBlacklist = Utils.hashSet(Lists.BlacklistedObjects),
    vehicleBlacklist = Utils.hashSet(Lists.BlacklistedVehicles),
    spawnPedBlacklist = Utils.hashSet(Lists.BlacklistedPeds),
    allowModels = Utils.hashSet(Config.Entities.allowModels),
    attachAllowModels = Utils.hashSet(Config.Entities.attachAllowModels),
    noSpawnResources = Utils.set(Config.Entities.noSpawnResources, true),
    weaponInfo = {},
}

-- weaponInfo[hash] = { name, group, range, rate, aim }
for group, names in pairs(Lists.Weapons) do
    local g = Lists.WeaponGroups[group]
    for _, name in ipairs(names) do
        Rempart.lookup.weaponInfo[Utils.joaat(name)] = {
            name = name, group = group,
            range = g.range * (Config.Combat.rangeMultiplier or 1.0),
            rate = g.rate, aim = g.aim,
        }
    end
end

-- Explosions bloquées (militaires selon config, troll toujours, + ajouts manuels)
Rempart.lookup.explosionPolicy = {}
do
    local allow = Utils.set(Config.Explosions.allowTypes)
    local block = Utils.set(Config.Explosions.blockTypes)
    for id, info in pairs(Lists.Explosions) do
        local class = info[2]
        local policy = 'allow'
        if class == 'troll' or (class == 'military' and not Config.Explosions.allowMilitary) then
            policy = 'block'
        elseif class == 'flag' then
            policy = 'flag'
        end
        if block[id] then policy = 'block' end
        if allow[id] then policy = 'allow' end
        Rempart.lookup.explosionPolicy[id] = policy
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Validation de la configuration (erreurs fréquentes)
-- ─────────────────────────────────────────────────────────────────────────────

Rempart.configWarnings = {}

local function cfgWarn(msg)
    Rempart.configWarnings[#Rempart.configWarnings + 1] = msg
end

for _, id in ipairs(unknownOverrides) do
    cfgWarn(('Config.Detections : détection inconnue « %s » (ignorée)'):format(id))
end
if Config.Risk.kick >= Config.Risk.ban then
    cfgWarn('Config.Risk : le seuil kick devrait être inférieur au seuil ban')
end
if Config.Bans.storage ~= 'kvp' and Config.Bans.storage ~= 'oxmysql' then
    cfgWarn(('Config.Bans.storage inconnu « %s », utilisation de kvp'):format(tostring(Config.Bans.storage)))
    Config.Bans.storage = 'kvp'
end
for id, d in pairs(Rempart.Detections) do
    if d.action ~= 'score' and d.action ~= 'kick' and d.action ~= 'ban' and d.action ~= 'log' then
        cfgWarn(('Détection %s : action « %s » invalide, remplacée par score'):format(id, tostring(d.action)))
        d.action = 'score'
    end
end

-- Les shields et le capteur retrouvent l'anti-cheat même s'il a été renommé.
SetConvarReplicated('rempart:resource', RES)
