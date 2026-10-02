--[[
    Rempart — registre des joueurs connectés.
]]

local Players = {}
Rempart.Players = Players

local registry = {}      -- src -> P
local memory = {}        -- license -> { score, ts, hist }

--- Identifiants d'un joueur (connecté ou en cours de connexion).
function Players.identify(src)
    local ids, idList = {}, {}
    for _, raw in ipairs(GetPlayerIdentifiers(src) or {}) do
        local kind, value = raw:match('^([^:]+):(.+)$')
        if kind and value then
            ids[kind] = raw
            idList[#idList + 1] = raw
        end
    end
    local tokens = {}
    for _, t in ipairs(GetPlayerTokens(src) or {}) do
        if type(t) == 'string' and t ~= '' then tokens[#tokens + 1] = t end
    end
    return ids, idList, tokens
end

local function create(src)
    local ids, idList, tokens = Players.identify(src)
    local now = Rempart.now()
    local P = {
        src = src,
        name = Utils.stripColors(GetPlayerName(src) or ('#' .. src)),
        joinedAt = os.time(),
        joinedMs = now,
        graceUntil = now + (Config.Movement.spawnGrace or 45) * 1000,
        ids = ids, idList = idList, tokens = tokens,
        risk = { score = 0.0, ts = now },
        hist = Utils.Ring(40),
        dcount = {},
        exempt = {},
        decl = { flags = {}, teleports = {} },
        admin = false, bypass = false, txAdmin = false,
        punished = false, quarantined = false,
        state = {},       -- scratchpad des modules (mouvement, combat…)
    }
    -- Restaure le score si le joueur s'est reconnecté récemment.
    local lic = ids.license
    local mem = lic and memory[lic]
    if mem and (os.time() - mem.ts) < Config.Risk.rememberSeconds then
        P.risk.score = mem.score
        for _, h in ipairs(mem.hist or {}) do P.hist:push(h) end
    end
    if lic then memory[lic] = nil end
    registry[src] = P
    return P
end

function Players.get(src)
    return registry[tonumber(src) or -1]
end

--- Récupère ou crée l'enregistrement (utile après un redémarrage de la ressource).
function Players.ensure(src)
    src = tonumber(src)
    if not src or src <= 0 then return nil end
    local P = registry[src]
    if P then return P end
    if not GetPlayerName(src) then return nil end
    P = create(src)
    Rempart.Perms.refresh(P)
    return P
end

--- Itération sur les joueurs connectés : for src, P in Players.each() do … end
function Players.each()
    return pairs(registry)
end

function Players.count()
    return Utils.count(registry)
end

--- Retrouve un joueur par id serveur, licence ou fragment de nom.
function Players.find(query)
    query = tostring(query or '')
    local n = tonumber(query)
    if n and registry[n] then return registry[n] end
    for _, P in pairs(registry) do
        for _, id in ipairs(P.idList) do
            if id == query then return P end
        end
    end
    local lower = query:lower()
    for _, P in pairs(registry) do
        if P.name:lower():find(lower, 1, true) then return P end
    end
    return nil
end

--- Joueur propriétaire d'un ped joueur (handle serveur), ou nil.
function Players.fromPed(ped)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return nil end
    if not IsPedAPlayer(ped) then return nil end
    local owner = NetworkGetEntityOwner(ped)
    if owner and owner > 0 and GetPlayerPed(owner) == ped then
        return registry[owner]
    end
    -- repli : recherche linéaire (ped en cours de migration)
    for src, P in pairs(registry) do
        if GetPlayerPed(src) == ped then return P end
    end
    return nil
end

function Players.inGrace(P)
    return Rempart.now() < (P.graceUntil or 0)
end

--- Prolonge la période de grâce (réapparition, changement de modèle, téléportation serveur…).
function Players.grace(P, seconds)
    local untilMs = Rempart.now() + seconds * 1000
    if untilMs > (P.graceUntil or 0) then P.graceUntil = untilMs end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Cycle de vie
-- ─────────────────────────────────────────────────────────────────────────────

AddEventHandler('playerJoining', function()
    local src = tonumber(source)
    if not src then return end
    local P = create(src)
    Rempart.Perms.refresh(P)
    Rempart.Log.file('join', { src = src, name = P.name, ids = P.idList, tokens = #P.tokens })
end)

AddEventHandler('playerDropped', function(reason)
    local src = tonumber(source)
    local P = src and registry[src]
    if not P then return end
    if P.ids.license and not P.punished then
        memory[P.ids.license] = { score = Rempart.Punish.currentScore(P), ts = os.time(), hist = P.hist:list() }
    end
    Rempart.Log.file('drop', { src = src, name = P.name, reason = reason, score = Utils.round(P.risk.score, 1) })
    registry[src] = nil
    TriggerEvent(Rempart.EV_SHIELD .. ':drop', src)
end)

-- Nettoyage périodique de la mémoire des scores.
CreateThread(function()
    while true do
        Wait(300000)
        local limit = os.time() - Config.Risk.rememberSeconds
        for lic, mem in pairs(memory) do
            if mem.ts < limit then memory[lic] = nil end
        end
    end
end)
