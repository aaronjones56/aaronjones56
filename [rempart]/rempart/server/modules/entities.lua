--[[
    Module : entités (entityCreating / entityCreated) — 100 % serveur.

    Seules les entités de MISSION (créées par script, population 7) sont contrôlées :
    la circulation, les piétons et les objets de carte déplacés ne le sont jamais.

    1. Liste noire de modèles (props de crash/cage, véhicules militaires…)
    2. Limiteur de débit par joueur et par type (seau à jetons)
    3. Origine du script : chaque ressource cliente s'exécute dans un thread dont le
       hash = joaat(nom de la ressource). GetEntityScript retrouve donc la ressource
       qui a créé l'entité. Script inconnu du serveur => exécuteur Lua.
       Ressource qui ne crée jamais d'entités (chat, spawnmanager…) => injection.
    4. Objets attachés au ped d'un autre joueur (cages, props troll).
    5. Création à distance : entité qui apparaît au contact d'un AUTRE joueur alors que son
       créateur est loin (cages, pluie de véhicules, PNJ hostiles « sur » un joueur).
    6. Ramassables (argent, armes, soins) : limiteur de débit dédié.
]]

local M = Rempart.module('entities', {})
local cfg = Config.Entities
local lookup = Rempart.lookup

local POP_MISSION = 7
local NET_TYPE_PLAYER, NET_TYPE_DOOR, NET_TYPE_PICKUP, NET_TYPE_PICKUP_PLACEMENT = 11, 3, 7, 8
local TYPE_NAMES = { [1] = 'ped', [2] = 'vehicle', [3] = 'object' }

M.stats = {}   -- ressource -> { ped = n, vehicle = n, object = n }

local function bucket(P, kind)
    local st = P.state
    st.spawnBuckets = st.spawnBuckets or {}
    local b = st.spawnBuckets[kind]
    if not b then
        local lim = cfg.limits[kind]
        b = Utils.TokenBucket(lim.rate, lim.burst, Rempart.now())
        st.spawnBuckets[kind] = b
    end
    return b
end

local function modelLabel(model, list)
    return list and list[model] or ('0x%08X'):format(model)
end

local function coordsText(entity)
    local c = GetEntityCoords(entity)
    return ('%.1f, %.1f, %.1f'):format(c.x, c.y, c.z)
end

local function blacklistFor(kind)
    if kind == 'ped' then return lookup.spawnPedBlacklist end
    if kind == 'vehicle' then return lookup.vehicleBlacklist end
    return lookup.objectBlacklist
end

--- Autre joueur (que `owner`) à moins de `radius` m de `pos`, ou nil.
local function victimNear(owner, pos, radius)
    local r2 = radius * radius
    for src, V in Rempart.Players.each() do
        if src ~= owner then
            local ped = GetPlayerPed(src)
            if ped and ped ~= 0 then
                local c = GetEntityCoords(ped)
                local dx, dy, dz = c.x - pos.x, c.y - pos.y, c.z - pos.z
                if dx * dx + dy * dy + dz * dz <= r2 then return V end
            end
        end
    end
    return nil
end

--- 5. Création à distance sur un autre joueur. Retourne true si l'entité doit être bloquée.
local function remoteSpawn(owner, entity, kind, model)
    local rs = cfg.remoteSpawn
    if not rs or not rs.enabled then return false end
    local ped = GetPlayerPed(owner)
    if not ped or ped == 0 then return false end
    local pos, oc = GetEntityCoords(entity), GetEntityCoords(ped)
    local far = (kind == 'object') and rs.objectDistance or rs.otherDistance
    if Utils.dist3(pos.x, pos.y, pos.z, oc.x, oc.y, oc.z) <= far then return false end
    local V = victimNear(owner, pos, rs.victimRadius)
    if not V then return false end
    Rempart.Detect(owner, 'entity_remote_spawn', {
        type = kind, modele = modelLabel(model), victime = ('%s (#%d)'):format(V.name, V.src),
        distance_createur = math.floor(Utils.dist3(pos.x, pos.y, pos.z, oc.x, oc.y, oc.z)) .. ' m',
    }, { score = (kind == 'object') and nil or 25 })
    return kind == 'object'
end

local function deleteLater(entity)
    SetTimeout(0, function()
        if DoesEntityExist(entity) then DeleteEntity(entity) end
    end)
end

--- Contrôle de l'origine du script (peut être différé : le nœud peut arriver après la création).
local function checkScript(owner, entity, kind, model, attempt)
    if not DoesEntityExist(entity) then return end
    local script = GetEntityScript(entity)

    if script then
        local s = M.stats[script]
        if not s then
            s = { ped = 0, vehicle = 0, object = 0 }
            M.stats[script] = s
        end
        s[kind] = s[kind] + 1
        if lookup.noSpawnResources[script:lower()] then
            Rempart.Detect(owner, 'entity_forbidden_res', {
                ressource = script, type = kind, modele = modelLabel(model), position = coordsText(entity),
            })
            deleteLater(entity)
        end
        return
    end

    if attempt < 2 then
        -- le nœud d'information de script peut arriver un peu après la création
        SetTimeout(1500, function() checkScript(owner, entity, kind, model, attempt + 1) end)
        return
    end

    if not cfg.unknownScript then return end
    if kind == 'object' then
        -- les objets attachés (parachute, props tenus) sont créés par des tâches du jeu
        if GetEntityAttachedTo(entity) ~= 0 then return end
    end
    if not Rempart.Players.get(owner) then return end
    Rempart.Detect(owner, 'entity_unknown_script', {
        type = kind, modele = modelLabel(model), position = coordsText(entity),
    }, { score = (kind == 'object') and 45 or nil })
    deleteLater(entity)
end

AddEventHandler('entityCreating', function(entity)
    if not cfg.enabled then return end
    if GetEntityPopulationType(entity) ~= POP_MISSION then return end

    local owner = NetworkGetFirstEntityOwner(entity)
    if not owner or owner <= 0 then return end
    local P = Rempart.Players.get(owner)
    if not P then return end

    local netType = GetNetTypeFromEntity(entity)
    if netType == NET_TYPE_PLAYER or netType == NET_TYPE_DOOR then return end
    if Rempart.Perms.immune(P, Rempart.Detections.entity_blacklisted) then return end

    -- 6. Ramassables : débit seulement (les menus « money drop » en génèrent des centaines)
    if netType == NET_TYPE_PICKUP or netType == NET_TYPE_PICKUP_PLACEMENT then
        if cfg.limits.pickup and not bucket(P, 'pickup'):take(Rempart.now()) then
            CancelEvent()
            local st = P.state
            st.pickupDropped = (st.pickupDropped or 0) + 1
            if st.pickupDropped % 5 == 1 then
                Rempart.Detect(owner, 'entity_spam', { type = 'pickup', refuses = st.pickupDropped })
            end
        end
        return
    end

    local etype = GetEntityType(entity)
    local kind = TYPE_NAMES[etype]
    if not kind then return end

    local model = Utils.h32(GetEntityModel(entity))
    if lookup.allowModels[model] then return end

    -- 1. Liste noire
    local list = blacklistFor(kind)
    if list[model] then
        CancelEvent()
        Rempart.Detect(owner, 'entity_blacklisted', {
            type = kind, modele = modelLabel(model, list), position = coordsText(entity),
        })
        return
    end

    -- 2. Débit
    if not bucket(P, kind):take(Rempart.now()) then
        CancelEvent()
        local st = P.state
        st.spawnDropped = (st.spawnDropped or 0) + 1
        if st.spawnDropped % 5 == 1 then
            Rempart.Detect(owner, 'entity_spam', { type = kind, refuses = st.spawnDropped, modele = modelLabel(model) })
        end
        return
    end

    -- 5. Création au contact d'un autre joueur, loin du créateur
    if remoteSpawn(owner, entity, kind, model) then
        CancelEvent()
        return
    end

    -- 3. Origine du script
    checkScript(owner, entity, kind, model, 0)
end)

-- 4. Attachements à d'autres joueurs (l'attachement n'existe qu'après la création)
AddEventHandler('entityCreated', function(entity)
    if not cfg.enabled or not cfg.attachToPlayers then return end
    if not DoesEntityExist(entity) or GetEntityPopulationType(entity) ~= POP_MISSION then return end
    local owner = NetworkGetFirstEntityOwner(entity)
    if not owner or owner <= 0 or not Rempart.Players.get(owner) then return end

    SetTimeout(1000, function()
        if not DoesEntityExist(entity) then return end
        local target = GetEntityAttachedTo(entity)
        if target == 0 or not DoesEntityExist(target) then return end
        if GetEntityType(target) ~= 1 or not IsPedAPlayer(target) then return end
        if target == GetPlayerPed(owner) then return end
        local model = Utils.h32(GetEntityModel(entity))
        if lookup.attachAllowModels[model] or lookup.allowModels[model] then return end
        -- un ped joueur attaché à un autre (porter/escorter) est légitime
        if GetEntityType(entity) == 1 and IsPedAPlayer(entity) then return end
        local victim = Rempart.Players.fromPed(target)
        Rempart.Detect(owner, 'entity_attach_player', {
            modele = modelLabel(model), victime = victim and ('%s (#%d)'):format(victim.name, victim.src) or '?',
        })
        DeleteEntity(entity)
    end)
end)
