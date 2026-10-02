--[[
    Rempart — client : poignée de main, canal signé, heartbeat, déclarations.

    Le client ne décide JAMAIS d'une sanction : il signale, le serveur recoupe et décide.
    Toute la configuration utile est reçue du serveur à l'exécution (rien en clair dans
    le cache du client).
]]

local RES = GetCurrentResourceName()
local EV_C2S, EV_S2C = RES .. ':c', RES .. ':s'
local VERSION = '1.0.0'

-- Références capturées au chargement (un script injecté plus tard dans ce même
-- environnement ne peut pas détourner silencieusement ces fonctions).
local TriggerServerEvent, GetGameTimer, Wait, CreateThread = TriggerServerEvent, GetGameTimer, Wait, CreateThread
local signature = Utils.signature

RMP = {
    modules = {},
    cfg = nil,
    ready = false,
    serverResources = {},
    decl = {},            -- kind -> { v, t, r }
    graceUntil = 0,
}

local key, seq = nil, 0
local detectSent = {}     -- id -> ms (anti-spam local)
local sentWindow = Utils.Window(60000)

-- ─────────────────────────────────────────────────────────────────────────────
-- Canal
-- ─────────────────────────────────────────────────────────────────────────────

function RMP.send(kind, payload, extra)
    if not key then return end
    seq = seq + 1
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
        while true do
            local now = GetGameTimer()
            for _, mod in ipairs(RMP.modules) do
                if mod.tick and (not mod.nextRun or now >= mod.nextRun) then
                    mod.nextRun = now + (mod.interval or 1000)
                    local ok, err = pcall(mod.tick, now)
                    if not ok then print(('[Rempart] %s : %s'):format(mod.name, tostring(err))) end
                end
            end
            Wait(250)
        end
    end)
end

RegisterNetEvent(EV_S2C, function(kind, data)
    if kind == 'init' and type(data) == 'table' then
        key, seq = data.key, 0
        RMP.cfg = data.cfg or {}
        RMP.setServerResources(data.resources)
        RMP.grace(RMP.cfg.spawnGrace or 45)
        if not RMP.ready then
            RMP.ready = true
            startModules()
        end
    elseif kind == 'ping' and type(data) == 'table' then
        RMP.send('pong', { n = data.n, rc = GetNumResources() }, data.nonce)
    elseif kind == 'resources' then
        RMP.setServerResources(data)
    end
end)

-- Poignée de main dès que le joueur est actif sur le réseau (relancée tant que le
-- serveur n'a pas répondu, ex. anti-cheat serveur encore en démarrage).
CreateThread(function()
    while not NetworkIsPlayerActive(PlayerId()) do Wait(500) end
    Wait(1500)
    for _ = 1, 10 do
        TriggerServerEvent(EV_C2S, 'hello', 0, '', { v = VERSION, res = RMP.listResources() })
        Wait(20000)
        if key then break end
    end
end)
