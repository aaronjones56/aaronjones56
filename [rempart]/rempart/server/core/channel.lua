--[[
    Rempart — canal sécurisé client <-> serveur.

    1. Le client anti-cheat démarre et envoie 'hello' (liste de ses ressources).
    2. Le serveur génère une clé de session aléatoire (256 bits) et la renvoie ('init').
    3. Chaque message client est signé : HMAC-SHA256(clé, type|séquence|extra),
       la séquence est strictement croissante (anti-rejeu).
    4. Heartbeat : défi aléatoire toutes les N secondes ; la réponse doit être signée
       avec la clé ET contenir le défi. Sans réponse valide → kick (jamais de ban,
       une connexion instable ne doit pas bannir). Réponse falsifiée → ban.
    5. Les rapports de détection client sont recoupés avec la vérité serveur
       (état réel des ressources, etc.) avant toute sanction.
]]

local Channel = {}
Rempart.Channel = Channel

local handlers = {}           -- type de message -> function(P, payload)
local prevKeys = {}           -- src -> { key, untilMs } (rotation de clé)
local resChanges = {}         -- nom de ressource -> ms du dernier start/stop côté serveur

--- Enregistre un gestionnaire pour un type de message client.
function Channel.on(kind, fn)
    handlers[kind] = fn
end

--- Envoie un message au client anti-cheat d'un joueur.
function Channel.send(src, kind, data)
    TriggerClientEvent(Rempart.EV_S2C, src, kind, data)
end

local function newKey()
    local seed = table.concat({
        tostring(math.random(0, 0x7fffffff)), tostring(math.random(0, 0x7fffffff)),
        tostring(os.time()), tostring(os.clock()), tostring(Rempart.now()),
        tostring(os.nanotime and os.nanotime() or 0), tostring({}),
    }, ':')
    return Sha256.hex(seed .. Utils.randomHex(32))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Liste des ressources (vérité serveur)
-- ─────────────────────────────────────────────────────────────────────────────

function Channel.serverResources()
    local list = {}
    for i = 0, GetNumResources() - 1 do
        local name = GetResourceByFindIndex(i)
        if name then
            local state = GetResourceState(name)
            if state == 'started' or state == 'starting' then list[#list + 1] = name end
        end
    end
    return list
end

--- La ressource a-t-elle changé d'état côté serveur récemment ?
function Channel.recentlyChanged(name, windowMs)
    local t = resChanges[name]
    return t ~= nil and (Rempart.now() - t) < (windowMs or 120000)
end

--- La ressource existe-t-elle (ou a-t-elle existé) côté serveur ?
function Channel.isServerResource(name)
    if type(name) ~= 'string' or name == '' then return false end
    local state = GetResourceState(name)
    return state ~= 'missing' and state ~= 'unknown'
end

local function onResourceChange(name)
    resChanges[name] = Rempart.now()
    -- informe les clients (liste à jour) — regroupé pour les redémarrages en série
    if not Channel._broadcastPending then
        Channel._broadcastPending = true
        SetTimeout(1500, function()
            Channel._broadcastPending = false
            local list = Channel.serverResources()
            for src, P in Rempart.Players.each() do
                if P.session then Channel.send(src, 'resources', list) end
            end
        end)
    end
end

AddEventHandler('onResourceStart', onResourceChange)
AddEventHandler('onResourceStop', onResourceChange)

-- ─────────────────────────────────────────────────────────────────────────────
-- Configuration envoyée au client (sous-ensemble : jamais les webhooks, bans…)
-- ─────────────────────────────────────────────────────────────────────────────

local function clientConfig()
    local weapons = {}
    for h in pairs(Rempart.lookup.weaponBlacklist) do weapons[#weapons + 1] = h end
    return {
        checks = Config.Client.checks,
        freecamDistance = Config.Client.freecamDistance,
        noclipHeight = Config.Client.noclipHeight,
        vehicleSpeedFactor = Config.Client.vehicleSpeedFactor,
        weaponBlacklist = weapons,
        maxDamageModifier = Config.PlayerState.maxWeaponDamageModifier,
        maxMeleeModifier = Config.PlayerState.maxMeleeDamageModifier,
        cheatCommands = Lists.CheatCommands,
        cheatTextures = Lists.CheatTextures,
        spawnGrace = Config.Movement.spawnGrace,
    }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Réception
-- ─────────────────────────────────────────────────────────────────────────────

local function verify(P, kind, seq, mac, extra)
    local s = P.session
    if not s then return false, 'nosession' end
    seq = math.tointeger(seq)
    if not seq or type(mac) ~= 'string' then return false, 'malformed' end
    local ok = Utils.signature(s.key, kind, seq, extra) == mac
    if not ok then
        local prev = prevKeys[P.src]
        if prev and prev.untilMs > Rempart.now() and Utils.signature(prev.key, kind, seq, extra) == mac then
            ok = true
        end
    end
    if not ok then return false, 'badmac' end
    if seq <= s.seq then return false, 'replay' end
    s.seq = seq
    return true
end

local function startSession(P, payload)
    if P.session then
        -- seconde poignée de main dans la même session serveur : le module client a redémarré
        prevKeys[P.src] = { key = P.session.key, untilMs = Rempart.now() + 15000 }
        Rempart.Log.debug('%s (#%d) : nouvelle poignée de main (client redémarré)', P.name, P.src)
    end
    P.session = {
        key = newKey(),
        seq = 0,
        createdMs = Rempart.now(),
        lastPongMs = Rempart.now(),
        missed = 0,
        pending = nil,
        n = 0,
        version = type(payload) == 'table' and tostring(payload.v or '?') or '?',
    }
    Channel.send(P.src, 'init', {
        key = P.session.key,
        cfg = clientConfig(),
        resources = Channel.serverResources(),
    })
    -- vérifie la liste de ressources annoncée par le client
    if type(payload) == 'table' and type(payload.res) == 'table' then
        Channel.checkClientResources(P, payload.res)
    end
end

RegisterNetEvent(Rempart.EV_C2S, function(kind, seq, mac, payload, extra)
    local src = tonumber(source)
    if not src or type(kind) ~= 'string' then return end
    local P = Rempart.Players.ensure(src)
    if not P or P.punished then return end

    -- limite de débit du canal (protège le serveur du spam de messages) ;
    -- le heartbeat n'y est jamais soumis : il ne doit pas pouvoir être affamé.
    if kind ~= 'pong' and kind ~= 'hello' then
        local st = P.state
        st.chanBucket = st.chanBucket or Utils.TokenBucket(5, 40, Rempart.now())
        if not st.chanBucket:take(Rempart.now()) then return end
    end

    if kind == 'hello' then
        -- 1 poignée de main / 10 s : chaque 'hello' renvoie la configuration (anti-amplification)
        local now = Rempart.now()
        if P.state.lastHello and now - P.state.lastHello < 10000 then return end
        P.state.lastHello = now
        return startSession(P, payload)
    end

    local ok, why = verify(P, kind, seq, mac, extra)
    if not ok then
        if why == 'badmac' then
            P.state.badMacs = (P.state.badMacs or 0) + 1
            -- tolérance : un message en vol pendant une rotation de clé
            if P.state.badMacs >= 3 then
                Rempart.Detect(src, 'heartbeat_tamper', { reason = 'signature invalide', kind = kind })
            end
        elseif why == 'replay' then
            P.state.replays = (P.state.replays or 0) + 1
            if P.state.replays >= 5 then
                Rempart.Detect(src, 'heartbeat_tamper', { reason = 'rejeu de messages', kind = kind })
            end
        end
        return
    end

    local h = handlers[kind]
    if h then
        local okh, err = pcall(h, P, payload, extra)
        if not okh then Rempart.Log.error('Canal : erreur sur « %s » : %s', kind, tostring(err)) end
    end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Heartbeat
-- ─────────────────────────────────────────────────────────────────────────────

Channel.on('pong', function(P, payload, extra)
    local s = P.session
    local pend = s.pending
    if not pend or type(payload) ~= 'table' then return end
    if extra ~= pend.nonce or math.tointeger(payload.n) ~= pend.n then return end
    s.pending = nil
    s.missed = 0
    s.lastPongMs = Rempart.now()
    s.rtt = s.lastPongMs - pend.sentMs
    s.clientResCount = math.tointeger(payload.rc)
end)

local function heartbeatTick()
    if not Config.Client.enabled then return end
    local now = Rempart.now()
    local interval = Config.Client.heartbeatInterval * 1000
    for src, P in Rempart.Players.each() do
        if not P.punished then
            local s = P.session
            if not s then
                if (now - P.joinedMs) > Config.Client.helloTimeout * 1000 then
                    Rempart.Detect(src, 'client_missing', { attente = Config.Client.helloTimeout .. ' s' },
                        { reason = L('client_missing') })
                end
            elseif (now - (s.lastPingMs or 0)) >= interval then
                if s.pending then
                    s.missed = s.missed + 1
                    if s.missed >= Config.Client.maxMissed then
                        Rempart.Detect(src, 'heartbeat_timeout', {
                            defis_manques = s.missed,
                            dernier_pong = math.floor((now - s.lastPongMs) / 1000) .. ' s',
                        }, { reason = L('client_timeout') })
                    end
                end
                s.n = s.n + 1
                s.lastPingMs = now
                s.pending = { n = s.n, nonce = Utils.randomHex(16), sentMs = now }
                Channel.send(src, 'ping', { n = s.n, nonce = s.pending.nonce })
            end
        end
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Recoupement des ressources client
-- ─────────────────────────────────────────────────────────────────────────────

-- Ressources internes du client FiveM (n'existent pas forcément côté serveur).
local function isInternal(name)
    return name:find('^_+cfx') ~= nil
end

--- Signale les ressources présentes chez le client mais inconnues du serveur.
function Channel.checkClientResources(P, names)
    local unknown = {}
    for i, name in ipairs(names) do
        if i > 1024 then break end
        if type(name) == 'string' and not isInternal(name) and not Channel.isServerResource(name)
            and not Channel.recentlyChanged(name) then
            unknown[#unknown + 1] = name
        end
    end
    if #unknown > 0 then
        Rempart.Detect(P.src, 'resource_injected', { ressources = table.concat(unknown, ', ') })
    end
end

Channel.on('res', function(P, payload)
    if type(payload) == 'table' then Channel.checkClientResources(P, payload) end
end)

-- Ressource arrêtée localement alors qu'elle tourne côté serveur => resource stopper.
-- Confirmation différée : quand un joueur quitte le jeu, ses ressources s'arrêtent
-- aussi ; seul un joueur TOUJOURS connecté 10 s plus tard est concerné.
Channel.on('stop', function(P, payload)
    local name = type(payload) == 'table' and payload.name
    if type(name) ~= 'string' or isInternal(name) then return end
    local src = P.src
    SetTimeout(10000, function()
        local cur = Rempart.Players.get(src)
        if not cur or cur ~= P or not GetPlayerName(src) then return end
        if GetResourceState(name) == 'started' and not Channel.recentlyChanged(name, 70000) then
            Rempart.Detect(src, 'resource_stopped', { ressource = name })
        end
    end)
end)

CreateThread(function()
    while true do
        Wait(1000)
        local ok, err = pcall(heartbeatTick)
        if not ok then Rempart.Log.error('Heartbeat : %s', tostring(err)) end
    end
end)

AddEventHandler('playerDropped', function()
    prevKeys[tonumber(source) or -1] = nil
end)
