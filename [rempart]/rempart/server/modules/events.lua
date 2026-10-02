--[[
    Module : événements réseau.

    1. Registre statique : analyse des scripts serveur de toutes les ressources pour
       recenser les VRAIS événements réseau (RegisterNetEvent/RegisterServerEvent/onNet).
    2. Pièges (honeypots) : armés uniquement s'ils n'existent pas sur le serveur
       (ni dans le registre, ni par préfixe de ressource, ni désarmés par apprentissage).
       Pièges « forts » (noms qu'aucun script n'utilise) et motifs (« DFWM »).
    3. Capteur (ressource rempart_sensor) : observe TOUS les événements réseau grâce à
       l'abonnement joker '*' de FXServer, et remonte pièges/floods/rafales/inconnus.
    4. Hôte du pare-feu : les shields (inclus dans vos ressources) reçoivent les règles
       et la liste de quarantaine, et remontent les violations.
    5. Attestation : chaque shield client compte les TriggerServerEvent de SA ressource ;
       le module anti-cheat envoie ces compteurs (message signé) ; le capteur compte ce que
       le serveur a réellement reçu. Un événement protégé reçu plus souvent qu'il n'a été
       attesté vient d'un code extérieur à vos ressources (exécuteur « ressource isolée »,
       trigger finder qui rejoue des événements…).
]]

local M = Rempart.module('events', {})
Rempart.Events = M
local cfg = Config.Events

M.registry = {}          -- nom d'événement réseau serveur -> ressource
M.prefixes = {}          -- préfixes dynamiques ('esx_jobs:' .. x) -> true
M.escrowed = {}          -- ressources chiffrées (non analysables) -> true
M.honeypots = {}         -- pièges armés : nom -> 1 (classique) | 2 (fort)
M.shields = {}           -- ressources protégées par le shield -> ms d'enregistrement
M.protected = {}         -- événements réseau des ressources avec shield : nom -> ressource
M.unshielded = {}        -- noms cités par le code client des ressources SANS shield -> ressource
M.unshieldedPrefixes = {}
M.mixed = {}             -- appris : événement aussi déclenché hors shield -> raison
M.unattestableRes = {}   -- ressources avec shield dont une partie du code client n'est pas en Lua
M.misplacedShields = {}  -- ressources dont le shield n'est pas le premier script
M.sensorOnline = false

local disarmed = {}      -- pièges désarmés par apprentissage : nom -> raison
local honeyHits = {}     -- nom -> { [license] = true }
local unattestedBy = {}  -- nom -> { [license] = true }
local lastStart = -1e9   -- ms du dernier démarrage d'une autre ressource
local strong = Utils.set(Lists.HoneypotsStrong)

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
-- Code client : déclenchements dynamiques ('prefix:' .. x) et chaînes littérales citées.
local CLIENT_DYN_PATTERNS = {
    'TriggerServerEvent%s*%(%s*[\'"]([^\'"]+)[\'"]%s*%.%.',
    'TriggerLatentServerEvent%s*%(%s*[\'"]([^\'"]+)[\'"]%s*%.%.',
    'emitNet%s*%(%s*[\'"`]([^\'"`]+)[\'"`]%s*%+',
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

--- Code client d'une ressource sans shield : tout ce qu'elle peut déclencher sans attestation.
local function indexUnshieldedClient(res, content)
    for _, q in ipairs({ '"', "'", '`' }) do
        for lit in content:gmatch(q .. '([%w_%-:%./@]+)' .. q) do
            if #lit >= 3 and #lit <= 128 then M.unshielded[lit] = M.unshielded[lit] or res end
        end
    end
    for _, pat in ipairs(CLIENT_DYN_PATTERNS) do
        for prefix in content:gmatch(pat) do
            if #prefix >= 3 then M.unshieldedPrefixes[prefix] = true end
        end
    end
end

--- Code client que le shield ne compte pas : toute la ressource sans shield, et les scripts
--- non-Lua (JS, C#) d'une ressource avec shield. Retourne le nombre de fichiers lus.
local function indexClientCallers(res)
    if not (cfg.attestation and cfg.attestation.enabled) or res == Rempart.res then return 0 end
    local shielded = Rempart.Files.hasShield(res)
    if shielded and not Rempart.Files.shieldFirst(res) then M.misplacedShields[res] = true end
    local n = 0
    for _, f in ipairs(Rempart.Files.scripts(res, 'client')) do
        local isLua = f.path:lower():match('%.lua$') ~= nil
        if not shielded or not isLua then
            if f.path:lower():match('%.dll$') then
                M.unattestableRes[res] = true   -- binaire (C#) : appels impossibles à recenser
            else
                local content, escrowed = Rempart.Files.read(f.res, f.path)
                if escrowed and shielded then
                    M.unattestableRes[res] = true
                elseif content and not escrowed then
                    n = n + 1
                    indexUnshieldedClient(f.owner, content)
                end
            end
        end
    end
    return n
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
        files = files + indexClientCallers(res)
        Wait(0)
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
    local armed = 0
    local function arm(name, level)
        if not disabled[name] and not disarmed[name] and not M.isKnown(name) then
            if not M.honeypots[name] then armed = armed + 1 end
            M.honeypots[name] = math.max(M.honeypots[name] or 0, level)
        end
    end
    for _, n in ipairs(Lists.Honeypots) do arm(n, strong[n] and 2 or 1) end
    for _, n in ipairs(Lists.HoneypotsStrong) do arm(n, 2) end
    for _, n in ipairs(cfg.extraHoneypots or {}) do arm(n, 1) end
    return armed
end

--- Événements client pièges à armer (ressource cible absente du serveur).
function M.clientHoneypots()
    local out = {}
    if not cfg.honeypots then return out end
    for _, h in ipairs(Lists.ClientHoneypots) do
        local name = h[1]
        local res = h.res or name:match('^([^:]+):')
        if res and GetResourceState(res) == 'missing' then
            out[#out + 1] = name
        end
    end
    return out
end

--- Score d'un piège client armé (nil si inconnu).
function M.clientHoneypotScore(name)
    for _, h in ipairs(Lists.ClientHoneypots) do
        if h[1] == name then return h.score or Rempart.Detections.client_honeypot.score end
    end
    return nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Attestation : quels événements surveiller
-- ─────────────────────────────────────────────────────────────────────────────

--- Un appel non attesté de cet événement est-il anormal ?
function M.attestable(name)
    local res = M.protected[name]
    if not res or M.mixed[name] or M.unshielded[name] or M.unattestableRes[res] then return false end
    for prefix in pairs(M.unshieldedPrefixes) do
        if name:sub(1, #prefix) == prefix then return false end
    end
    return true
end

local function trackedNames()
    local out = {}
    if not (cfg.attestation and cfg.attestation.enabled) then return out end
    for name in pairs(M.protected) do
        if M.attestable(name) then out[name] = true end
    end
    return out
end

local function sensorConfig()
    local s = cfg.sensor
    return {
        honeypots = M.honeypots,
        patterns = Lists.HoneypotPatterns,
        known = M.registry,
        prefixes = M.prefixes,
        escrowed = M.escrowed,
        flood = s.floodPerSecond,
        burst = s.burstDistinct,
        maxPayload = s.maxPayload,
        unknown = s.unknownScore,
        joinGrace = s.joinGrace,
        tracked = trackedNames(),
        channel = Rempart.EV_C2S,
        ignore = { [Rempart.EV_C2S] = true, [Rempart.res .. ':w'] = true },
    }
end

local pushPending = false
function M.pushSensorConfig()
    TriggerEvent(Rempart.EV_SENSOR .. ':config', sensorConfig())
end

--- Regroupe les envois de configuration (les shields s'annoncent en rafale au démarrage).
local function schedulePush()
    if pushPending then return end
    pushPending = true
    SetTimeout(1000, function()
        pushPending = false
        M.pushSensorConfig()
        Rempart.Channel.broadcastShielded()
    end)
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
local function onHoneypot(src, name, size, retried, pattern)
    if not pattern and not M.honeypots[name] then return end
    local P = Rempart.Players.get(src)
    if not P then return end
    if M.isKnown(name) then
        armHoneypots()
        return M.pushSensorConfig()
    end
    -- une ressource vient de démarrer : attendre la fin de son indexation (2 s) avant de juger
    if not retried and Rempart.now() - lastStart < 6000 then
        return SetTimeout(4000, function() onHoneypot(src, name, size, true, pattern) end)
    end
    local level = pattern and 2 or M.honeypots[name]
    if level ~= 2 then
        local lic = P.ids.license or tostring(src)
        honeyHits[name] = honeyHits[name] or {}
        honeyHits[name][lic] = true
        if Utils.count(honeyHits[name]) >= 3 then
            return disarm(name, 'déclenché par 3 joueurs distincts')
        end
    end
    local details = { evenement = name, taille = size, motif = pattern }
    -- Un piège classique peut exister dans une ressource chiffrée (escrow) que l'analyse
    -- statique ne peut pas lire : on le dégrade alors en score (une autre preuve sera exigée).
    if level ~= 2 and next(M.escrowed) ~= nil then
        details.prudence = 'ressources chiffrées présentes'
        return Rempart.Detect(src, 'event_honeypot', details, { action = 'score', score = 60 })
    end
    Rempart.Detect(src, 'event_honeypot', details)
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
        onHoneypot(src, tostring(data.event), data.size, false, type(data.pattern) == 'string' and data.pattern or nil)
    elseif kind == 'active' then
        P.activeMs = P.activeMs or Rempart.now()
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
-- Attestation : rapprochement compteurs attestés (client signé) / reçus (capteur)
-- ─────────────────────────────────────────────────────────────────────────────

local function attState(P)
    local a = P.state.attest
    if not a then
        a = { pending = {}, prevAtt = nil, prevRx = nil }
        P.state.attest = a
    end
    return a
end

local function reportUnattested(P, name, count)
    local ac = cfg.attestation
    local lic = P.ids.license or ('#' .. P.src)
    local by = unattestedBy[name] or {}
    unattestedBy[name] = by
    by[lic] = true
    if Utils.count(by) >= (ac.learnPlayers or 3) then
        -- plusieurs joueurs distincts : un script légitime sans shield déclenche cet événement
        M.mixed[name] = 'appelé hors shield par plusieurs joueurs'
        Rempart.Storage.set('attest_mixed', M.mixed)
        Rempart.Log.warn('Attestation : « %s » est aussi déclenché par une ressource sans shield (désormais ignoré).', name)
        schedulePush()
        return
    end
    local now = Rempart.now()
    local st = P.state
    st.unattested = st.unattested or {}
    st.unattested[name] = now
    local distinct = 0
    for n, t in pairs(st.unattested) do
        if now - t > 600000 then st.unattested[n] = nil else distinct = distinct + 1 end
    end
    Rempart.Detect(P.src, 'event_unattested', {
        evenement = name, appels = count, ressource = M.protected[name], evenements_distincts = distinct,
    }, { score = distinct >= (ac.escalateNames or 3) and 60 or nil })
end

local function reconcile(P, att, rx)
    local a = attState(P)
    local prevAtt, prevRx = a.prevAtt, a.prevRx
    a.prevAtt, a.prevRx = att, rx
    if not prevAtt then return end   -- premier rapprochement de la session : référence
    for name, count in pairs(rx) do
        if type(name) == 'string' and M.attestable(name) then
            local received = (tonumber(count) or 0) - (tonumber(prevRx[name]) or 0)
            local attested = (tonumber(att[name]) or 0) - (tonumber(prevAtt[name]) or 0)
            -- attesté > reçu : événements perdus (limiteur de FXServer…) — sans gravité
            if received - attested > 0 then
                reportUnattested(P, name, received - attested)
            end
        end
    end
end

local function tryPair(P, seq)
    local a = attState(P)
    local e = a.pending[seq]
    if e and e.att and e.rx then
        a.pending[seq] = nil
        reconcile(P, e.att, e.rx)
    end
    -- purge des entrées orphelines (capteur absent, message perdu)
    local now = Rempart.now()
    for k, v in pairs(a.pending) do
        if now - v.ms > 15000 then a.pending[k] = nil end
    end
end

--- Compteurs attestés reçus par le canal signé (appelé par le canal après vérification).
function M.onAttestation(P, seq, counts)
    if not (cfg.attestation and cfg.attestation.enabled) or type(counts) ~= 'table' then return end
    local a = attState(P)
    local e = a.pending[seq] or { ms = Rempart.now() }
    e.att = counts
    a.pending[seq] = e
    tryPair(P, seq)
end

--- Nouvelle session anti-cheat : les compteurs client repartent de zéro.
function M.resetAttestation(P)
    P.state.attest = nil
end

-- Instantané des compteurs reçus, pris par le capteur au passage du message d'attestation.
AddEventHandler(Rempart.EV_SENSOR .. ':rx', function(src, seq, counts)
    if not isLocal() then return end
    local P = Rempart.Players.get(tonumber(src))
    seq = math.tointeger(seq)
    if not P or not seq or type(counts) ~= 'table' then return end
    local a = attState(P)
    local e = a.pending[seq] or { ms = Rempart.now() }
    e.rx = counts
    a.pending[seq] = e
    tryPair(P, seq)
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

local function addProtected(resource, names)
    if type(names) ~= 'table' then return end
    for i, name in ipairs(names) do
        if i > 2048 then break end
        if type(name) == 'string' and #name <= 128 and not M.protected[name] then
            M.protected[name] = resource
        end
    end
end

AddEventHandler(Rempart.EV_SHIELD .. ':hello', function(resource, netEvents)
    if not isLocal() or type(resource) ~= 'string' then return end
    M.shields[resource] = Rempart.now()
    addProtected(resource, netEvents)
    TriggerEvent(Rempart.EV_SHIELD .. ':policy', firewallPolicy())
    schedulePush()
end)

-- Événement réseau enregistré par une ressource avec shield après son annonce
AddEventHandler(Rempart.EV_SHIELD .. ':net', function(resource, name)
    if not isLocal() or type(resource) ~= 'string' or type(name) ~= 'string' then return end
    addProtected(resource, { name })
    schedulePush()
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

--- Ressources dont le shield est actif (pour le module client : collecte des compteurs).
function M.shieldedList()
    local list = {}
    for res in pairs(M.shields) do list[#list + 1] = res end
    table.sort(list)
    return list
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Initialisation
-- ─────────────────────────────────────────────────────────────────────────────

function M.init()
    disarmed = Rempart.Storage.get('honeypots_disarmed', {})
    M.mixed = Rempart.Storage.get('attest_mixed', {})
    CreateThread(function()
        local files, resources = 0, 0
        if cfg.staticScan then files, resources = M.buildRegistry() end
        local armed = armHoneypots()
        Rempart.Log.info('Événements : %d événements réseau recensés (%d fichiers, %d ressources), %d pièges armés.',
            Utils.count(M.registry), files, resources, armed)
        for res in pairs(M.misplacedShields) do
            Rempart.Log.warn('Shield mal placé dans « %s » : mettez « shared_script \'@%s/shield.lua\' » AVANT tout '
                .. 'autre script (sinon une partie de ses événements échappe à l\'attestation).', res, Rempart.res)
        end
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
        indexClientCallers(res)
        armHoneypots()
        M.pushSensorConfig()
    end)
end)

AddEventHandler('onResourceStop', function(res)
    if M.shields[res] then
        M.shields[res] = nil
        schedulePush()
    end
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
