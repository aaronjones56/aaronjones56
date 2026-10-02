--[[
    ██ Rempart Shield ██  — à inclure EN PREMIER dans le fxmanifest de vos ressources :

        shared_script '@rempart/shield.lua'

    (remplacez « rempart » par le nom du dossier si vous l'avez renommé)

    CÔTÉ SERVEUR — pare-feu d'événements BLOQUANT pour cette ressource :
      • limite de débit par joueur et par événement (règles par défaut + Config.Events.firewall.rules)
      • arguments malformés rejetés (NaN, infini, chaînes géantes, tables abyssales)
      • règles déclaratives : serverOnly, ace, distance (near/radius), débit (rate/per)
      • quarantaine : un joueur en cours de sanction ne peut plus rien déclencher
      • intentions : SetEntityCoords / FreezeEntityPosition / SetPlayerInvincible /
        GiveWeaponToPed appliqués par vos scripts serveur sont signalés comme légitimes

    CÔTÉ CLIENT — déclarations d'intentions :
      quand VOTRE script téléporte le joueur, le rend invisible/invincible, coupe ses
      collisions, active une caméra scriptée, le mode spectateur, répare son véhicule…
      l'anti-cheat en est informé et ne le confond pas avec un tricheur. Un exécuteur
      qui appelle les natives directement ne déclare rien et reste détecté.

    Le shield est passif tant que l'anti-cheat n'est pas démarré, et chaque appel
    est protégé : il ne peut pas casser la ressource qui l'inclut.
]]

if _G.__rempart_shield then return end
_G.__rempart_shield = true

local RES = GetCurrentResourceName()
local AC = GetConvar('rempart:resource', 'rempart')
if RES == AC then return end

local pcall, type, tonumber, pairs, ipairs = pcall, type, tonumber, pairs, ipairs
local IS_SERVER = IsDuplicityVersion()

if IS_SERVER then
    -- ═════════════════════════════════════════════════════════════════════════
    --  SERVEUR : pare-feu d'événements
    -- ═════════════════════════════════════════════════════════════════════════

    local _RegisterNetEvent, _AddEventHandler = RegisterNetEvent, AddEventHandler
    local GetGameTimer, TriggerEvent = GetGameTimer, TriggerEvent
    local EV = AC .. ':shield'

    local netEvents = {}          -- événements réseau enregistrés par cette ressource
    local policy = nil            -- reçue de l'anti-cheat
    local quarantined = {}
    local buckets = {}            -- src -> nom -> { tokens, last }
    local reportedAt = {}         -- clé -> ms

    local function isLocalSource()
        local s = source
        return s == nil or s == '' or not tonumber(s)
    end

    local function report(src, name, kind, info)
        local key = src .. '|' .. name .. '|' .. kind
        local now = GetGameTimer()
        if reportedAt[key] and now - reportedAt[key] < 5000 then return end
        reportedAt[key] = now
        TriggerEvent(EV .. ':violation', src, RES, name, kind, info)
    end

    local function take(src, name, rate, burst)
        local per = buckets[src]
        if not per then
            per = {}
            buckets[src] = per
        end
        local now = GetGameTimer()
        local b = per[name]
        if not b then
            b = { tokens = burst, last = now }
            per[name] = b
        end
        local elapsed = (now - b.last) / 1000.0
        if elapsed > 0 then
            b.tokens = math.min(burst, b.tokens + elapsed * rate)
            b.last = now
        end
        if b.tokens >= 1 then
            b.tokens = b.tokens - 1
            return true
        end
        return false
    end

    local huge = math.huge
    local function inspect(v, L, depth, budget)
        local tv = type(v)
        if tv == 'number' then
            if v ~= v then return 'NaN' end
            if v == huge or v == -huge then return 'infini' end
            if L.maxNumber and (v > L.maxNumber or v < -L.maxNumber) then return 'nombre démesuré' end
        elseif tv == 'string' then
            if #v > L.maxString then return ('chaîne de %d octets'):format(#v) end
        elseif tv == 'table' then
            if depth >= L.maxDepth then return 'profondeur excessive' end
            for k, x in pairs(v) do
                budget.n = budget.n + 1
                if budget.n > L.maxNodes then return 'table trop volumineuse' end
                local why = inspect(k, L, depth + 1, budget) or inspect(x, L, depth + 1, budget)
                if why then return why end
            end
        end
        return nil
    end

    --- Retourne true si l'appel doit être bloqué.
    local function firewall(src, name, ...)
        if quarantined[src] then return true end
        if not policy then return false end
        local rule = policy.rules and policy.rules[name]

        if rule and rule.serverOnly then
            report(src, name, 'serverOnly', {})
            return true
        end

        local rate, burst = policy.rate or 25, policy.burst or 60
        if rule and rule.rate then
            local per = rule.per or 1
            rate = rule.rate / per
            burst = rule.burst or rule.rate
        end
        if not take(src, name, rate, burst) then
            report(src, name, 'rate', { limite = rule and ('%s/%ss'):format(rule.rate, rule.per or 1) or 'défaut' })
            return true
        end

        if rule and rule.ace and not IsPlayerAceAllowed(src, rule.ace) then
            report(src, name, 'ace', { ace = rule.ace })
            return true
        end

        if rule and rule.near then
            local ped = GetPlayerPed(src)
            local ok = false
            if ped and ped ~= 0 then
                local c = GetEntityCoords(ped)
                local r = rule.radius or 25.0
                for _, p in ipairs(rule.near) do
                    local dx, dy, dz = c.x - p.x, c.y - p.y, c.z - p.z
                    if dx * dx + dy * dy + dz * dz <= r * r then ok = true break end
                end
            end
            if not ok then
                report(src, name, 'distance', { rayon = rule.radius or 25.0 })
                return true
            end
        end

        local L = policy.limits
        if L then
            local budget = { n = 0 }
            for i = 1, select('#', ...) do
                local why = inspect((select(i, ...)), L, 0, budget)
                if why then
                    report(src, name, 'malformed', { argument = i, anomalie = why })
                    return true
                end
            end
        end
        return false
    end

    local function wrap(name, fn)
        return function(...)
            local src = source
            local n = tonumber(src)
            if n and n > 0 and netEvents[name] then
                local ok, blocked = pcall(firewall, n, name, ...)
                if ok and blocked then return end
            end
            return fn(...)
        end
    end

    function AddEventHandler(name, fn, ...)
        if type(name) == 'string' and type(fn) == 'function' then
            return _AddEventHandler(name, wrap(name, fn), ...)
        end
        return _AddEventHandler(name, fn, ...)
    end

    function RegisterNetEvent(name, cb)
        if type(name) == 'string' then netEvents[name] = true end
        _RegisterNetEvent(name)
        if cb then return AddEventHandler(name, cb) end
    end
    RegisterServerEvent = RegisterNetEvent

    -- Communication avec l'anti-cheat (événements serveur-locaux)
    _AddEventHandler(EV .. ':policy', function(p)
        if not isLocalSource() or type(p) ~= 'table' then return end
        policy = p
        quarantined = {}
        for src in pairs(p.quarantined or {}) do quarantined[tonumber(src) or src] = true end
    end)

    _AddEventHandler(EV .. ':quarantine', function(src, flag)
        if not isLocalSource() then return end
        src = tonumber(src)
        if src then quarantined[src] = flag and true or nil end
    end)

    _AddEventHandler(EV .. ':drop', function(src)
        if not isLocalSource() then return end
        src = tonumber(src)
        if src then
            quarantined[src], buckets[src] = nil, nil
        end
    end)

    local function hello() TriggerEvent(EV .. ':hello', RES) end
    _AddEventHandler('onResourceStart', function(res)
        if res == AC then SetTimeout(1000, hello) end
    end)
    CreateThread(function()
        Wait(500)
        if GetResourceState(AC) == 'started' then hello() end
    end)

    -- Intentions des scripts serveur (natives exécutées par cette ressource)
    local function playerOfPed(entity)
        if not entity or entity == 0 or not DoesEntityExist(entity) then return nil end
        if GetEntityType(entity) ~= 1 or not IsPedAPlayer(entity) then return nil end
        local owner = NetworkGetEntityOwner(entity)
        return (owner and owner > 0) and owner or nil
    end

    local function intent(kind, src, data)
        pcall(TriggerEvent, EV .. ':intent', kind, src, data)
    end

    local _SetEntityCoords = SetEntityCoords
    if _SetEntityCoords then
        SetEntityCoords = function(entity, x, y, z, ...)
            pcall(function()
                local src = playerOfPed(entity)
                if src then intent('teleport', src, { x = x, y = y, z = z }) end
            end)
            return _SetEntityCoords(entity, x, y, z, ...)
        end
    end

    local _FreezeEntityPosition = FreezeEntityPosition
    if _FreezeEntityPosition then
        FreezeEntityPosition = function(entity, toggle, ...)
            pcall(function()
                local src = playerOfPed(entity)
                if src then intent('frozen', src, toggle == true) end
            end)
            return _FreezeEntityPosition(entity, toggle, ...)
        end
    end

    local _SetPlayerInvincible = SetPlayerInvincible
    if _SetPlayerInvincible then
        SetPlayerInvincible = function(player, toggle, ...)
            pcall(intent, 'invincible', tonumber(player), toggle == true)
            return _SetPlayerInvincible(player, toggle, ...)
        end
    end

    local _GiveWeaponToPed = GiveWeaponToPed
    if _GiveWeaponToPed then
        GiveWeaponToPed = function(ped, ...)
            pcall(function()
                local src = playerOfPed(ped)
                if src then intent('weapon', src, true) end
            end)
            return _GiveWeaponToPed(ped, ...)
        end
    end
else
    -- ═════════════════════════════════════════════════════════════════════════
    --  CLIENT : déclarations d'intentions
    -- ═════════════════════════════════════════════════════════════════════════

    local GetGameTimer, PlayerPedId, PlayerId = GetGameTimer, PlayerPedId, PlayerId
    local lastSent = {}   -- kind -> { value, ms }

    local function declare(kind, value, x, y, z)
        local now = GetGameTimer()
        local prev = lastSent[kind]
        -- anti-surcharge : beaucoup de scripts appellent ces natives à CHAQUE image.
        -- États : uniquement au changement (ou toutes les 2 s). Téléportations : 1 toutes les 500 ms.
        if prev then
            if kind == 'tp' then
                if now - prev.t < 500 then return end
            elseif prev.v == value and now - prev.t < 2000 then
                return
            end
        end
        lastSent[kind] = { v = value, t = now }
        pcall(function() exports[AC]:Declare(kind, value, RES, x, y, z) end)
    end

    local function isMe(entity)
        local ped = PlayerPedId()
        return entity == ped
    end

    local function isMyVehicle(entity)
        local veh = GetVehiclePedIsIn(PlayerPedId(), false)
        return veh ~= 0 and entity == veh
    end

    local function hook(name, fn)
        local original = _G[name]
        if type(original) ~= 'function' then return end
        _G[name] = function(...)
            pcall(fn, ...)
            return original(...)
        end
    end

    -- Téléportations
    local function tpEntity(entity, x, y, z)
        if isMe(entity) or isMyVehicle(entity) then declare('tp', true, x, y, z) end
    end
    hook('SetEntityCoords', tpEntity)
    hook('SetEntityCoordsNoOffset', tpEntity)
    hook('SetPedCoordsKeepVehicle', tpEntity)
    hook('SetEntityCoordsWithoutPlantsReset', tpEntity)
    hook('StartPlayerTeleport', function(player, x, y, z)
        if player == PlayerId() then declare('tp', true, x, y, z) end
    end)
    hook('NetworkResurrectLocalPlayer', function(x, y, z) declare('tp', true, x, y, z) end)

    -- Visibilité, invincibilité, collisions, gel
    hook('SetEntityVisible', function(entity, toggle)
        if isMe(entity) then declare('invisible', not toggle) end
    end)
    hook('SetEntityInvincible', function(entity, toggle)
        if isMe(entity) then declare('invincible', toggle == true)
        elseif isMyVehicle(entity) then declare('vehiclegod', toggle == true) end
    end)
    hook('SetEntityCanBeDamaged', function(entity, toggle)
        if isMe(entity) then declare('invincible', not toggle)
        elseif isMyVehicle(entity) then declare('vehiclegod', not toggle) end
    end)
    hook('SetEntityProofs', function(entity, bullet, fire, explosion, collision, melee)
        local any = bullet or fire or explosion or collision or melee
        if isMe(entity) then declare('invincible', any == true)
        elseif isMyVehicle(entity) then declare('vehiclegod', any == true) end
    end)
    hook('SetPlayerInvincible', function(player, toggle)
        if player == PlayerId() then declare('invincible', toggle == true) end
    end)
    hook('SetPlayerInvincibleKeepRagdollEnabled', function(player, toggle)
        if player == PlayerId() then declare('invincible', toggle == true) end
    end)
    hook('SetEntityCollision', function(entity, toggle)
        if isMe(entity) then declare('collision', not toggle) end
    end)
    hook('FreezeEntityPosition', function(entity, toggle)
        if isMe(entity) then declare('frozen', toggle == true) end
    end)

    -- Caméras, spectateur, visions
    hook('RenderScriptCams', function(render) declare('camera', render == true) end)
    hook('NetworkSetInSpectatorMode', function(toggle) declare('spectate', toggle == true) end)
    hook('NetworkSetInSpectatorModeExtended', function(toggle) declare('spectate', toggle == true) end)
    hook('SetSeethrough', function(toggle) declare('vision', toggle == true) end)
    hook('SetNightvision', function(toggle) declare('vision', toggle == true) end)
    hook('SetPedCanRagdoll', function(ped, toggle)
        if isMe(ped) then declare('ragdoll', not toggle) end
    end)
    hook('SetSuperJumpThisFrame', function(player)
        if player == PlayerId() then declare('superjump', true) end
    end)

    -- Véhicules
    hook('SetVehicleCheatPowerIncrease', function(veh, value)
        if isMyVehicle(veh) then declare('vehiclepower', (tonumber(value) or 1.0) > 1.05) end
    end)
    hook('ModifyVehicleTopSpeed', function(veh, value)
        if isMyVehicle(veh) then declare('vehiclepower', (tonumber(value) or 0) > 0) end
    end)
    local function repaired(veh)
        if isMyVehicle(veh) then declare('repair', true) end
    end
    hook('SetVehicleFixed', repaired)
    hook('SetVehicleDeformationFixed', repaired)
    hook('SetVehicleEngineHealth', repaired)
    hook('SetVehicleBodyHealth', repaired)

    -- Témoin : l'anti-cheat s'arrête alors que cette ressource tourne encore
    AddEventHandler('onClientResourceStop', function(res)
        if res ~= AC then return end
        SetTimeout(math.random(0, 3000), function()
            TriggerServerEvent(AC .. ':w', 'acstop', RES)
        end)
    end)
end
