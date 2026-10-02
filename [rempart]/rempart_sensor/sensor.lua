--[[
    Rempart Sensor — capteur global des événements réseau.

    FXServer distribue chaque événement aux ressources abonnées à son nom… ou au joker '*'.
    Cette ressource s'abonne à '*' et remplace sa propre routine d'événements : elle voit
    TOUS les événements déclenchés par les clients (TriggerServerEvent), y compris ceux
    qu'aucune ressource n'enregistre — exactement ce qu'envoient les menus de triche
    avec leurs listes de « triggers ».

    Elle ne fait qu'OBSERVER (jamais d'annulation, jamais de modification) et remonte à
    l'anti-cheat : pièges déclenchés, floods, rafales d'événements distincts, charges
    démesurées, événements inexistants, + une trace forensique des 40 derniers
    événements de chaque joueur (jointe aux bans).

    Isolée dans sa propre ressource pour ne jamais perturber la logique d'événements
    de l'anti-cheat ni d'aucune autre ressource.
]]

local AC = GetConvar('rempart:resource', 'rempart')
local EV = AC .. ':sensor'
local SELF = GetCurrentResourceName()

local GetGameTimer, TriggerEvent, tonumber, sub = GetGameTimer, TriggerEvent, tonumber, string.sub
local unpack = msgpack.unpack

local cfg = nil
local players = {}       -- src -> stats
local seenBy = {}        -- événement inconnu -> { [src] = true } (apprentissage)
local learnedKnown = {}  -- événement inconnu vu chez 3 joueurs distincts => légitime

local TRAIL = 40

local function stats(src, now)
    local s = players[src]
    if not s then
        s = {
            joined = now,
            sec = now, secCount = 0, floodSecs = 0,
            burstStart = now, burstNames = {}, burstCount = 0,
            unknownCount = 0,
            trail = {}, trailPos = 0,
            reported = {},
        }
        players[src] = s
    end
    return s
end

local function report(src, kind, data, s, now, cooldown)
    local last = s.reported[kind]
    if last and now - last < (cooldown or 10000) then return end
    s.reported[kind] = now
    TriggerEvent(EV .. ':hit', src, kind, data)
end

local function isKnown(name)
    if cfg.known[name] or learnedKnown[name] then return true end
    for prefix in pairs(cfg.prefixes) do
        if sub(name, 1, #prefix) == prefix then return true end
    end
    local resPrefix = name:match('^([^:]+):')
    if resPrefix then
        if cfg.escrowed[resPrefix] then return true end
        local state = GetResourceState(resPrefix)
        if state ~= 'missing' and state ~= 'unknown' then return true end
    end
    return false
end

--- Traitement d'un événement réseau émis par un client.
local function onNet(name, src, size)
    local now = GetGameTimer()
    local s = stats(src, now)

    -- trace forensique (tampon circulaire)
    s.trailPos = (s.trailPos % TRAIL) + 1
    s.trail[s.trailPos] = { name, now, size }

    if cfg.ignore[name] or sub(name, 1, 5) == '__cfx' then return end

    -- 1. piège
    if cfg.honeypots[name] then
        TriggerEvent(EV .. ':hit', src, 'honeypot', { event = name, size = size })
    end

    -- 2. charge démesurée
    if size > cfg.maxPayload then
        report(src, 'payload', { event = name, size = size }, s, now, 30000)
    end

    local inGrace = (now - s.joined) < cfg.joinGrace * 1000

    -- 3. flood soutenu (secondes consécutives au-dessus du seuil)
    if now - s.sec >= 1000 then
        if s.secCount > cfg.flood then
            s.floodSecs = s.floodSecs + 1
            if s.floodSecs >= 5 and not inGrace then
                report(src, 'flood', { rate = s.secCount, count = s.floodSecs }, s, now, 30000)
                s.floodSecs = 0
            end
        else
            s.floodSecs = 0
        end
        s.sec, s.secCount = now, 0
    end
    s.secCount = s.secCount + 1

    -- 4. rafale d'événements distincts (« trigger all »)
    if now - s.burstStart > 5000 then
        s.burstStart, s.burstNames, s.burstCount = now, {}, 0
    end
    if not s.burstNames[name] then
        s.burstNames[name] = true
        s.burstCount = s.burstCount + 1
        if s.burstCount >= cfg.burst and not inGrace then
            local sample, n = {}, 0
            for k in pairs(s.burstNames) do
                n = n + 1
                if n > 6 then break end
                sample[#sample + 1] = k
            end
            report(src, 'burst', { distinct = s.burstCount, sample = table.concat(sample, ', ') }, s, now, 30000)
        end
    end

    -- 5. événement inexistant sur ce serveur
    if cfg.unknown and not cfg.honeypots[name] and not isKnown(name) then
        local by = seenBy[name]
        if not by then
            by = {}
            seenBy[name] = by
        end
        if not by[src] then
            by[src] = true
            local distinct = 0
            for _ in pairs(by) do distinct = distinct + 1 end
            if distinct >= 3 then
                learnedKnown[name] = true   -- utilisé par plusieurs joueurs : légitime
                seenBy[name] = nil
                return
            end
        end
        s.unknownCount = s.unknownCount + 1
        if not inGrace and (s.unknownCount == 3 or s.unknownCount % 15 == 0) then
            report(src, 'unknown', { event = name, count = s.unknownCount }, s, now, 20000)
        end
    end
end

local function trailOf(src)
    local s = players[src]
    if not s then return {} end
    local out = {}
    for i = 1, TRAIL do
        local idx = ((s.trailPos + i - 1) % TRAIL) + 1
        local e = s.trail[idx]
        if e then out[#out + 1] = { ev = e[1], ms = e[2], size = e[3] } end
    end
    return out
end

--- Routine d'événements de cette ressource (remplace celle du scheduler Lua).
local function routine(eventName, payload, eventSource)
    if sub(eventSource, 1, 4) == 'net:' then
        if cfg then
            local src = tonumber(sub(eventSource, 5))
            if src then
                local ok, err = pcall(onNet, eventName, src, #payload)
                if not ok then print('^1[rempart_sensor]^7 ' .. tostring(err)) end
            end
        end
        return
    end

    -- Événements serveur-locaux de contrôle (jamais acceptés depuis le réseau)
    if eventSource ~= '' and sub(eventSource, 1, 13) ~= 'internal-net:' then return end

    if eventName == EV .. ':config' then
        local ok, args = pcall(unpack, payload)
        if ok and type(args) == 'table' and type(args[1]) == 'table' then
            local c = args[1]
            c.known, c.prefixes, c.escrowed = c.known or {}, c.prefixes or {}, c.escrowed or {}
            c.honeypots, c.ignore = c.honeypots or {}, c.ignore or {}
            cfg = c
        end
    elseif eventName == EV .. ':dump' then
        local ok, args = pcall(unpack, payload)
        local src = ok and type(args) == 'table' and tonumber(args[1])
        if src then TriggerEvent(EV .. ':dumpResult', src, trailOf(src)) end
    elseif eventName == 'playerJoining' then
        local src = tonumber(sub(eventSource, 14))
        if src then
            players[src] = nil
            stats(src, GetGameTimer())
        end
    elseif eventName == 'playerDropped' then
        local src = tonumber(sub(eventSource, 14))
        if src then players[src] = nil end
    elseif eventName == 'onResourceStart' then
        local ok, args = pcall(unpack, payload)
        if ok and type(args) == 'table' and args[1] == AC then
            SetTimeout(3000, function() TriggerEvent(EV .. ':hello') end)
        end
    end
end

if type(Citizen.SetEventRoutine) ~= 'function' then
    print('^1[rempart_sensor]^7 Citizen.SetEventRoutine indisponible sur cette version de FXServer : capteur désactivé.')
    return
end

Citizen.SetEventRoutine(function(eventName, payload, eventSource)
    local ok, err = pcall(routine, eventName, payload or '', eventSource or '')
    if not ok then print('^1[rempart_sensor]^7 ' .. tostring(err)) end
end)
RegisterResourceAsEventHandler('*')

CreateThread(function()
    Wait(1000)
    TriggerEvent(EV .. ':hello')
    print(('^5[rempart_sensor]^7 Capteur actif (ressource « %s », anti-cheat « %s »).'):format(SELF, AC))
end)
