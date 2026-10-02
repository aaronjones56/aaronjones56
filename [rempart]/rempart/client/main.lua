--[[
    Rempart — client : poignée de main, canal signé, heartbeat, déclarations,
    attestation des événements, marqueur de ban, intégrité de l'environnement.

    Le client ne décide JAMAIS d'une sanction : il signale, le serveur recoupe et décide.
    Toute la configuration utile est reçue du serveur à l'exécution (rien en clair dans
    le cache du client).
]]

local RES = GetCurrentResourceName()
local EV_C2S, EV_S2C = RES .. ':c', RES .. ':s'
local VERSION = '1.1.0'

-- Références capturées au chargement (un script injecté plus tard dans ce même
-- environnement ne peut pas détourner silencieusement ces fonctions).
local TriggerServerEvent, GetGameTimer, Wait, CreateThread = TriggerServerEvent, GetGameTimer, Wait, CreateThread
local rawget, pairs, ipairs, pcall, type = rawget, pairs, ipairs, pcall, type
local signature = Utils.signature

RMP = {
    modules = {},
    cfg = nil,
    ready = false,
    serverResources = {},
    shielded = {},
    decl = {},            -- kind -> { v, t, r }
    graceUntil = 0,
}

local key, seq = nil, 0
local tx, txd = 0, 0      -- messages envoyés depuis l'ouverture de la session (dont détections)
local detectSent = {}     -- id -> ms (anti-spam local)
local sentWindow = Utils.Window(60000)

-- ─────────────────────────────────────────────────────────────────────────────
-- Canal
-- ─────────────────────────────────────────────────────────────────────────────

function RMP.send(kind, payload, extra)
    if not key then return end
    seq = seq + 1
    tx = tx + 1
    if kind == 'detect' then txd = txd + 1 end
    TriggerServerEvent(EV_C2S, kind, seq, signature(key, kind, seq, extra), payload, extra)
end

--- Signale une détection (dédupliquée : 1 par identifiant toutes les 15 s, 30/min max).
function RMP.detect(id, details)
    local now = GetGameTimer()
    if detectSent[id] and now - detectSent[id] < 15000 then return end
    if sentWindow:count(now) >= 30 then return end
    detectSent[id] = now
    sentWindow:add(now, id)
    RMP.send('detect', { id = id, d = details or {} })
end

function RMP.module(name, mod)
    mod.name = name
    RMP.modules[#RMP.modules + 1] = mod
    return mod
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Grâce (apparition, réanimation, chargement)
-- ─────────────────────────────────────────────────────────────────────────────

function RMP.grace(seconds)
    local t = GetGameTimer() + seconds * 1000
    if t > RMP.graceUntil then RMP.graceUntil = t end
end

function RMP.inGrace()
    return GetGameTimer() < RMP.graceUntil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Ressources
-- ─────────────────────────────────────────────────────────────────────────────

function RMP.listResources()
    local list = {}
    for i = 0, GetNumResources() - 1 do
        local name = GetResourceByFindIndex(i)
        if name then
            local state = GetResourceState(name)
            if state == 'started' or state == 'starting' or state == 'uninitialized' then
                list[#list + 1] = name
            end
        end
    end
    return list
end

function RMP.setServerResources(list)
    local set = {}
    for _, name in ipairs(list or {}) do set[name] = true end
    RMP.serverResources = set
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Déclarations d'intention (appelées par le shield des autres ressources)
-- ─────────────────────────────────────────────────────────────────────────────

local RELAYED = {
    invisible = true, invincible = true, collision = true, frozen = true, spectate = true, camera = true,
    vision = true, ragdoll = true, vehiclegod = true, vehiclepower = true, repair = true, superjump = true,
    heal = true,
}

--- kind : 'tp' | 'invisible' | 'invincible' | … ; value : bool (ou coordonnées pour 'tp')
function RMP.declare(kind, value, resource, x, y, z)
    local now = GetGameTimer()
    resource = type(resource) == 'string' and resource or '?'
    if kind == 'tp' then
        local prev = RMP.decl.tp
        RMP.decl.tp = { v = true, t = now, r = resource, sent = prev and prev.sent or 0, x = x, y = y, z = z }
        RMP.grace(3)
        -- relai au serveur limité à 1/s, sauf destination nettement différente
        local far = not prev or not prev.x or not x
            or ((prev.x - x) ^ 2 + (prev.y - y) ^ 2 + (prev.z - z) ^ 2) > 2500
        if far or now - RMP.decl.tp.sent > 1000 then
            RMP.decl.tp.sent = now
            RMP.send('decl', { k = 'tp', x = x, y = y, z = z, r = resource })
        end
        return
    end
    if not RELAYED[kind] then return end
    local prev = RMP.decl[kind]
    local v = value == true
    RMP.decl[kind] = { v = v, t = now, r = resource }
    -- relai serveur uniquement sur changement (ou rafraîchissement toutes les 10 s)
    if not prev or prev.v ~= v or (now - (prev.sent or 0)) > 10000 then
        RMP.decl[kind].sent = now
        RMP.send('decl', { k = kind, v = v, r = resource })
    else
        RMP.decl[kind].sent = prev.sent
    end
end

--- La déclaration est-elle active ?
function RMP.declared(kind, maxAgeMs)
    local d = RMP.decl[kind]
    if not d or not d.v then return false end
    if maxAgeMs and GetGameTimer() - d.t > maxAgeMs then return false end
    return true
end

exports('Declare', function(kind, value, resource, x, y, z)
    RMP.declare(kind, value, resource or GetInvokingResource(), x, y, z)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Shields des autres ressources : signatures de menus et rapports
-- ─────────────────────────────────────────────────────────────────────────────

--- Variables globales de menus à rechercher (le shield scanne l'environnement de SA ressource).
exports('ShieldGlobals', function()
    if not RMP.ready or (RMP.cfg.checks or {}).globals == false then return nil end
    return RMP.cfg.cheatGlobals
end)

--- Le shield d'une ressource a trouvé un menu Lua dans son environnement.
exports('ShieldReport', function(kind, data)
    local from = GetInvokingResource()
    if not RMP.ready or kind ~= 'lua_menu' or type(data) ~= 'table' then return end
    if not from or not RMP.serverResources[from] then return end
    RMP.detect('lua_menu', { variable = tostring(data.variable or '?'):sub(1, 64), ressource = from })
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Attestation des événements serveur déclenchés par les ressources avec shield
-- ─────────────────────────────────────────────────────────────────────────────

local att = { totals = {}, last = {}, names = 0, sentAt = 0 }

--- Lit les compteurs de chaque shield et les cumule (robuste aux redémarrages de ressource).
local function collectShieldCounts(baselineOnly)
    for res in pairs(RMP.shielded) do
        if res ~= RES and GetResourceState(res) == 'started' then
            local ok, counts = pcall(function() return exports[res]:__rmp_tx() end)
            if ok and type(counts) == 'table' then
                local last = att.last[res] or {}
                for name, n in pairs(counts) do
                    n = math.tointeger(n)
                    if type(name) == 'string' and n then
                        local prev = last[name] or 0
                        if not baselineOnly then
                            local delta = n >= prev and (n - prev) or n   -- n < prev : ressource redémarrée
                            if delta > 0 then
                                if not att.totals[name] then
                                    if att.names >= 1024 then delta = 0 else att.names = att.names + 1 end
                                end
                                if delta > 0 then att.totals[name] = (att.totals[name] or 0) + delta end
                            end
                        end
                        last[name] = n
                    end
                end
                att.last[res] = last
            end
        end
    end
end

local function setShielded(list)
    local set = {}
    for _, name in ipairs(list or {}) do set[name] = true end
    -- nouvelle ressource protégée : ses appels passés ne comptent pas (référence)
    for name in pairs(set) do
        if not RMP.shielded[name] then att.last[name] = nil end
    end
    RMP.shielded = set
end

local function attestationLoop()
    CreateThread(function()
        collectShieldCounts(true)
        while true do
            Wait(3000)
            if key and RMP.cfg.attest then
                collectShieldCounts(false)
                -- `tx`/`txd` comptent les messages envoyés AVANT celui-ci
                RMP.send('att', { t = att.totals, tx = tx, txd = txd })
            end
        end
    end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Marqueur de ban (KVP client + stockage NUI)
-- ─────────────────────────────────────────────────────────────────────────────

local cookie = { key = nil, kvp = nil, ls = nil, waiting = false }

local function sendCookie()
    if not cookie.waiting then return end
    cookie.waiting = false
    RMP.send('ck', { k = cookie.kvp, l = cookie.ls })
end

local function readCookie(ckKey)
    cookie.key = ckKey
    cookie.kvp = GetResourceKvpString(ckKey)
    cookie.ls = nil
    cookie.waiting = true
    SendNUIMessage({ rmp = 'ck_get', key = ckKey })
    SetTimeout(3000, sendCookie)   -- page NUI indisponible : on envoie quand même le KVP
end

RegisterNUICallback('ck', function(data, cb)
    cb('ok')
    if type(data) == 'table' and type(data.value) == 'string' then cookie.ls = data.value:sub(1, 64) end
    sendCookie()
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Intégrité de l'environnement de CE module (natives remplacées = injection ici)
-- ─────────────────────────────────────────────────────────────────────────────

local WATCHED = {
    'TriggerServerEvent', 'GetEntityCoords', 'GetEntityHealth', 'GetEntitySpeed', 'PlayerPedId', 'PlayerId',
    'GetSelectedPedWeapon', 'IsEntityVisible', 'GetEntityCanBeDamaged', 'GetPlayerInvincible', 'IsPedRagdoll',
    'NetworkIsInSpectatorMode', 'GetRegisteredCommands', 'GetNumResources', 'GetResourceByFindIndex',
    'GetResourceState', 'HasStreamedTextureDictLoaded', 'GetTextureResolution', 'GetPlayerWeaponDamageModifier',
    'GetPlayerMeleeWeaponDamageModifier', 'GetVehiclePedIsIn', 'GetEntityHeightAboveGround', 'GetGameplayCamCoord',
    'GetWeaponDamageType', 'GetModelDimensions',
}
local refs = {}
for _, n in ipairs(WATCHED) do refs[n] = _G[n] end   -- force le chargement paresseux des natives

local function checkEnvironment()
    if (RMP.cfg.checks or {}).envTamper == false then return end
    for n, ref in pairs(refs) do
        local cur = rawget(_G, n)
        if cur ~= ref then
            RMP.detect('client_env_tamper', { fonction = n })
            return
        end
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Événements client pièges (menus qui exploitent des scripts absents de ce serveur)
-- ─────────────────────────────────────────────────────────────────────────────

local honeypotsArmed = false

local function armClientHoneypots(list)
    if honeypotsArmed or (RMP.cfg.checks or {}).honeypots == false then return end
    honeypotsArmed = true
    for _, name in ipairs(list or {}) do
        if type(name) == 'string' then
            AddEventHandler(name, function()
                RMP.detect('client_honeypot', { evenement = name })
            end)
        end
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Réception serveur
-- ─────────────────────────────────────────────────────────────────────────────

local function startModules()
    for _, mod in ipairs(RMP.modules) do
        if mod.init then
            local ok, err = pcall(mod.init, RMP.cfg)
            if not ok then print(('[Rempart] module %s : %s'):format(mod.name, tostring(err))) end
        end
    end
    -- ordonnanceur unique : chaque module déclare `interval` (ms) et `tick(now)`
    CreateThread(function()
        local nextEnv = 0
        while true do
            local now = GetGameTimer()
            for _, mod in ipairs(RMP.modules) do
                if mod.tick and (not mod.nextRun or now >= mod.nextRun) then
                    mod.nextRun = now + (mod.interval or 1000)
                    local ok, err = pcall(mod.tick, now)
                    if not ok then print(('[Rempart] %s : %s'):format(mod.name, tostring(err))) end
                end
            end
            if now >= nextEnv then
                nextEnv = now + 20000
                checkEnvironment()
            end
            Wait(250)
        end
    end)
    attestationLoop()
end

RegisterNetEvent(EV_S2C, function(kind, data)
    if kind == 'init' and type(data) == 'table' then
        key, seq, tx, txd = data.key, 0, 0, 0
        att.totals, att.names = {}, 0
        RMP.cfg = data.cfg or {}
        RMP.setServerResources(data.resources)
        setShielded(data.shielded)
        RMP.grace(RMP.cfg.spawnGrace or 45)
        armClientHoneypots(RMP.cfg.clientHoneypots)
        if not RMP.ready then
            RMP.ready = true
            startModules()
        else
            collectShieldCounts(true)   -- nouvelle session : nouvelle référence
        end
        if type(RMP.cfg.cookie) == 'string' then readCookie(RMP.cfg.cookie) end
    elseif kind == 'ping' and type(data) == 'table' then
        RMP.send('pong', { n = data.n, rc = GetNumResources() }, data.nonce)
    elseif kind == 'resources' then
        RMP.setServerResources(data)
    elseif kind == 'shielded' then
        setShielded(data)
    elseif kind == 'setck' and type(data) == 'table' and type(data.v) == 'string' and cookie.key then
        SetResourceKvp(cookie.key, data.v)
        SendNUIMessage({ rmp = 'ck_set', key = cookie.key, value = data.v })
    end
end)

-- Poignée de main dès le démarrage (relancée tant que le serveur n'a pas répondu,
-- ex. anti-cheat serveur encore en démarrage).
CreateThread(function()
    Wait(1000)
    for _ = 1, 30 do
        TriggerServerEvent(EV_C2S, 'hello', 0, '', { v = VERSION, res = RMP.listResources() })
        Wait(11000)   -- le serveur accepte au plus une poignée de main toutes les 10 s
        if key then break end
    end
end)
