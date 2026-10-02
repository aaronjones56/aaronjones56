--[[
    Module : événements réseau.

    1. Registre statique : analyse des scripts serveur de toutes les ressources pour
       recenser les VRAIS événements réseau (RegisterNetEvent/RegisterServerEvent/onNet).
    2. Pièges (honeypots) : armés uniquement s'ils n'existent pas sur le serveur
       (ni dans le registre, ni par préfixe de ressource, ni désarmés par apprentissage).
    3. Capteur (ressource rempart_sensor) : observe TOUS les événements réseau grâce à
       l'abonnement joker '*' de FXServer, et remonte pièges/floods/rafales/inconnus.
    4. Hôte du pare-feu : les shields (inclus dans vos ressources) reçoivent les règles
       et la liste de quarantaine, et remontent les violations.
]]

local M = Rempart.module('events', {})
Rempart.Events = M
local cfg = Config.Events

M.registry = {}          -- nom d'événement réseau serveur -> ressource
M.prefixes = {}          -- préfixes dynamiques ('esx_jobs:' .. x) -> true
M.escrowed = {}          -- ressources chiffrées (non analysables) -> true
M.honeypots = {}         -- pièges armés : nom -> true
M.shields = {}           -- ressources protégées par le shield -> ms d'enregistrement
M.sensorOnline = false

local disarmed = {}      -- pièges désarmés par apprentissage : nom -> raison
local honeyHits = {}     -- nom -> { [license] = true }
local lastStart = -1e9   -- ms du dernier démarrage d'une autre ressource

-- ─────────────────────────────────────────────────────────────────────────────
-- Registre statique
-- ─────────────────────────────────────────────────────────────────────────────

local NET_PATTERNS = {
    'RegisterNetEvent%s*%(%s*[\'"]([^\'"]+)[\'"]',
    'RegisterServerEvent%s*%(%s*[\'"]([^\'"]+)[\'"]',
    'onNet%s*%(%s*[\'"`]([^\'"`]+)[\'"`]',
    'addNetEventListener%s*%(%s*[\'"`]([^\'"`]+)[\'"`]',
}
local DYN_PATTERNS = {
    'RegisterNetEvent%s*%(%s*[\'"]([^\'"]+)[\'"]%s*%.%.',
    'RegisterServerEvent%s*%(%s*[\'"]([^\'"]+)[\'"]%s*%.%.',
}

local function indexContent(res, content)
    for _, pat in ipairs(NET_PATTERNS) do
        for name in content:gmatch(pat) do
            if #name <= 128 then M.registry[name] = M.registry[name] or res end
        end
    end
    for _, pat in ipairs(DYN_PATTERNS) do
        for prefix in content:gmatch(pat) do
            if #prefix >= 3 then M.prefixes[prefix] = true end
        end
    end
end

function M.buildRegistry()
    local files, resources = 0, 0
    for _, res in ipairs(Rempart.Files.resources(true)) do
        resources = resources + 1
        for _, f in ipairs(Rempart.Files.scripts(res, 'server')) do
            local content, escrowed = Rempart.Files.read(f.res, f.path)
            if escrowed then
                M.escrowed[f.owner] = true
            elseif content then
                files = files + 1
                indexContent(f.owner, content)
            end
            if files % 25 == 0 then Wait(0) end
        end
    end
    return files, resources
end

--- L'événement existe-t-il (probablement) sur ce serveur ?
function M.isKnown(name)
    if M.registry[name] then return true end
    for prefix in pairs(M.prefixes) do
        if name:sub(1, #prefix) == prefix then return true end
    end
    local resPrefix = name:match('^([^:]+):')
    if resPrefix then
        local state = GetResourceState(resPrefix)
        if state ~= 'missing' and state ~= 'unknown' then return true end
        if M.escrowed[resPrefix] then return true end
    end
    return false
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Pièges
-- ─────────────────────────────────────────────────────────────────────────────

local function armHoneypots()
    M.honeypots = {}
    if not cfg.honeypots then return 0 end
    local disabled = Utils.set(cfg.disabledHoneypots)
    local candidates = {}
    for _, n in ipairs(Lists.Honeypots) do candidates[#candidates + 1] = n end
    for _, n in ipairs(cfg.extraHoneypots or {}) do candidates[#candidates + 1] = n end
    local armed = 0
    for _, name in ipairs(candidates) do
        if not disabled[name] and not disarmed[name] and not M.isKnown(name) then
            M.honeypots[name] = true
            armed = armed + 1
        end
    end
    return armed
end

local function sensorConfig()
    local s = cfg.sensor
    return {
        honeypots = M.honeypots,
        known = M.registry,
        prefixes = M.prefixes,
        escrowed = M.escrowed,
        flood = s.floodPerSecond,
        burst = s.burstDistinct,
        maxPayload = s.maxPayload,
        unknown = s.unknownScore,
        joinGrace = s.joinGrace,
        ignore = { [Rempart.EV_C2S] = true, [Rempart.res .. ':w'] = true },
    }
end

function M.pushSensorConfig()
    TriggerEvent(Rempart.EV_SENSOR .. ':config', sensorConfig())
end

-- Désarmement automatique : un « piège » déclenché par plusieurs joueurs distincts
-- est très probablement un événement légitime d'un script non analysable.
local function disarm(name, why)
    disarmed[name] = why
    M.honeypots[name] = nil
    Rempart.Storage.set('honeypots_disarmed', disarmed)
    M.pushSensorConfig()
    Rempart.Log.warn('Piège « %s » désarmé : %s', name, why)
    Rempart.Log.discord('system', Rempart.Log.embed({
        title = '🪤 Piège désarmé automatiquement',
        description = ('`%s` — %s'):format(name, why),
        color = Rempart.Log.colors.warn,
    }))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Remontées du capteur (événements serveur-locaux uniquement)
-- ─────────────────────────────────────────────────────────────────────────────

local function isLocal()
    local s = source
    return s == nil or s == '' or not tonumber(s)
end

--- Piège déclenché. Avant toute sanction, on revérifie que l'événement n'existe
--- pas (une ressource démarrée après l'armement peut l'avoir enregistré).
local function onHoneypot(src, name, size, retried)
    if not M.honeypots[name] then return end
    local P = Rempart.Players.get(src)
    if not P then return end
    if M.isKnown(name) then
        armHoneypots()
        return M.pushSensorConfig()
    end
    -- une ressource vient de démarrer : attendre la fin de son indexation (2 s) avant de juger
    if not retried and Rempart.now() - lastStart < 6000 then
        return SetTimeout(4000, function() onHoneypot(src, name, size, true) end)
    end
    local lic = P.ids.license or tostring(src)
    honeyHits[name] = honeyHits[name] or {}
    honeyHits[name][lic] = true
    if Utils.count(honeyHits[name]) >= 3 then
        return disarm(name, 'déclenché par 3 joueurs distincts')
    end
    Rempart.Detect(src, 'event_honeypot', { evenement = name, taille = size })
end

AddEventHandler(Rempart.EV_SENSOR .. ':hello', function()
    if not isLocal() then return end
    M.sensorOnline = true
    M.pushSensorConfig()
    Rempart.Log.ok('Capteur d\'événements connecté (rempart_sensor).')
end)

AddEventHandler(Rempart.EV_SENSOR .. ':hit', function(src, kind, data)
    if not isLocal() then return end
    src = tonumber(src)
    local P = src and Rempart.Players.get(src)
    if not P or type(data) ~= 'table' then return end

    if kind == 'honeypot' then
        onHoneypot(src, tostring(data.event), data.size, false)
    elseif kind == 'flood' then
        Rempart.Detect(src, 'event_flood', { par_seconde = data.rate, total = data.count })
    elseif kind == 'burst' then
        Rempart.Detect(src, 'event_burst', { distincts = data.distinct, fenetre = '5 s', exemples = data.sample })
    elseif kind == 'payload' then
        Rempart.Detect(src, 'event_payload', { evenement = tostring(data.event), octets = data.size })
    elseif kind == 'unknown' then
        Rempart.Detect(src, 'event_unknown', { evenement = tostring(data.event), nombre = data.count })
    end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Hôte du pare-feu (shields)
-- ─────────────────────────────────────────────────────────────────────────────

local function firewallPolicy()
    local fw = cfg.firewall
    local rules = {}
    for name, r in pairs(fw.rules or {}) do
        local rule = {}
        for k, v in pairs(r) do rule[k] = v end
        if r.near then
            rule.near = {}
            for i, c in ipairs(r.near) do rule.near[i] = { x = c.x, y = c.y, z = c.z } end
        end
        rules[name] = rule
    end
    local quarantined = {}
    for src, P in Rempart.Players.each() do
        if P.quarantined then quarantined[src] = true end
    end
    return {
        rate = fw.defaultRate, burst = fw.defaultBurst,
        limits = { maxString = fw.maxString, maxDepth = fw.maxDepth, maxNodes = fw.maxNodes, maxNumber = fw.maxNumber },
        rules = rules,
        quarantined = quarantined,
    }
end

AddEventHandler(Rempart.EV_SHIELD .. ':hello', function(resource)
    if not isLocal() or type(resource) ~= 'string' then return end
    M.shields[resource] = Rempart.now()
    TriggerEvent(Rempart.EV_SHIELD .. ':policy', firewallPolicy())
end)

AddEventHandler(Rempart.EV_SHIELD .. ':violation', function(src, resource, eventName, kind, info)
    if not isLocal() then return end
    src = tonumber(src)
    if not src or not Rempart.Players.get(src) then return end
    local details = { evenement = tostring(eventName), ressource = tostring(resource), regle = tostring(kind) }
    if type(info) == 'table' then
        for k, v in pairs(info) do details[tostring(k)] = v end
    end
    if kind == 'malformed' then
        Rempart.Detect(src, 'event_malformed', details)
    elseif kind == 'serverOnly' then
        Rempart.Detect(src, 'event_firewall', details, { score = 60 })
    else
        local rule = cfg.firewall.rules[eventName]
        Rempart.Detect(src, 'event_firewall', details, { score = rule and rule.score or nil })
    end
end)

-- Intentions déclarées par le shield côté serveur (scripts serveur légitimes)
AddEventHandler(Rempart.EV_SHIELD .. ':intent', function(kind, src, data)
    if not isLocal() then return end
    src = tonumber(src)
    local P = src and Rempart.Players.get(src)
    if not P then return end
    if kind == 'teleport' then
        Rempart.Movement.expect(src, type(data) == 'table' and data or nil, 10000)
        Rempart.Players.grace(P, 3)
    elseif kind == 'weapon' then
        Rempart.Perms.exempt(P, 'weapon_blacklisted', 5)
    elseif kind == 'invincible' or kind == 'frozen' or kind == 'invisible' then
        P.decl.flags[kind] = { v = data == true, r = 'serveur', t = Rempart.now() }
    end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Initialisation
-- ─────────────────────────────────────────────────────────────────────────────

function M.init()
    disarmed = Rempart.Storage.get('honeypots_disarmed', {})
    CreateThread(function()
        local files, resources = 0, 0
        if cfg.staticScan then files, resources = M.buildRegistry() end
        local armed = armHoneypots()
        Rempart.Log.info('Événements : %d événements réseau recensés (%d fichiers, %d ressources), %d pièges armés.',
            Utils.count(M.registry), files, resources, armed)
        M.pushSensorConfig()
        -- les shields déjà démarrés se réannoncent
        TriggerEvent(Rempart.EV_SHIELD .. ':policy', firewallPolicy())
    end)
end

-- Une ressource démarrée après coup peut enregistrer de nouveaux événements.
AddEventHandler('onResourceStart', function(res)
    if res == Rempart.res or not Rempart.ready then return end
    lastStart = Rempart.now()
    SetTimeout(2000, function()
        for _, f in ipairs(Rempart.Files.scripts(res, 'server')) do
            local content, escrowed = Rempart.Files.read(f.res, f.path)
            if escrowed then M.escrowed[res] = true elseif content then indexContent(res, content) end
        end
        armHoneypots()
        M.pushSensorConfig()
    end)
end)

AddEventHandler('onResourceStop', function(res)
    M.shields[res] = nil
end)

--- Rapport de couverture du shield.
function M.shieldCoverage()
    local covered, missing = {}, {}
    for _, res in ipairs(Rempart.Files.resources(true)) do
        if res ~= Rempart.res and res ~= 'rempart_sensor' then
            local hasClient = (GetNumResourceMetadata(res, 'client_script') or 0) > 0
            local hasServer = (GetNumResourceMetadata(res, 'server_script') or 0) > 0
            if hasClient or hasServer then
                if M.shields[res] then covered[#covered + 1] = res else missing[#missing + 1] = res end
            end
        end
    end
    return covered, missing
end
