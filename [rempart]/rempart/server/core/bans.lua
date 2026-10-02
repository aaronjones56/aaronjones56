--[[
    Rempart — gestionnaire de bannissements.

    Un ban correspond à TOUS les identifiants (license, license2, steam, discord, xbl,
    live, fivem, [ip]) et à TOUS les tokens matériels du joueur au moment du ban.
    À la connexion, la moindre correspondance suffit. Si un joueur banni revient avec
    un nouveau compte mais le même PC (tokens), le ban est étendu à ses nouveaux
    identifiants (Config.Bans.extendOnEvasion).
]]

local Bans = {}
Rempart.Bans = Bans

local bans = {}          -- id -> ban
local idIndex = {}       -- identifiant -> id du ban
local tokenIndex = {}    -- token -> id du ban

local indexedTypes = Utils.set(Config.Bans.identifiers)
if Config.Bans.useIp then indexedTypes.ip = true end

local function idType(identifier)
    return identifier:match('^([^:]+):')
end

local function shouldIndex(identifier)
    local t = idType(identifier)
    return t and indexedTypes[t] == true
end

local function index(ban)
    bans[ban.id] = ban
    for _, id in ipairs(ban.identifiers or {}) do
        if shouldIndex(id) then idIndex[id] = ban.id end
    end
    if Config.Bans.useTokens then
        for _, t in ipairs(ban.tokens or {}) do tokenIndex[t] = ban.id end
    end
end

local function unindex(ban)
    bans[ban.id] = nil
    for _, id in ipairs(ban.identifiers or {}) do
        if idIndex[id] == ban.id then idIndex[id] = nil end
    end
    for _, t in ipairs(ban.tokens or {}) do
        if tokenIndex[t] == ban.id then tokenIndex[t] = nil end
    end
end

local function isExpired(ban)
    return (ban.expiresAt or 0) > 0 and os.time() >= ban.expiresAt
end

local function newId()
    for _ = 1, 50 do
        local id = ('%s-%s'):format(Config.Bans.idPrefix, Utils.randomCode(6))
        if not bans[id] then return id end
    end
    return ('%s-%s'):format(Config.Bans.idPrefix, Utils.randomCode(10))
end

--- Recharge entièrement les bans depuis le stockage.
function Bans.load(cb)
    Rempart.Storage.bans.loadAll(function(list)
        bans, idIndex, tokenIndex = {}, {}, {}
        local expired = 0
        for _, ban in ipairs(list) do
            if isExpired(ban) then
                expired = expired + 1
                Rempart.Storage.bans.delete(ban.id)
            else
                index(ban)
            end
        end
        if cb then cb(Utils.count(bans), expired) end
    end)
end

--- Crée un ban. Champs : name, reason, identifiers, tokens, duration (s, 0 = définitif),
--- detection, details, by. Retourne l'enregistrement.
function Bans.add(opts)
    local ban = {
        id = newId(),
        name = opts.name or '?',
        reason = opts.reason or L('ban_generic'),
        detection = opts.detection,
        details = opts.details,
        identifiers = opts.identifiers or {},
        tokens = Config.Bans.useTokens and (opts.tokens or {}) or {},
        createdAt = os.time(),
        expiresAt = (opts.duration and opts.duration > 0) and (os.time() + opts.duration) or 0,
        by = opts.by or 'Rempart',
        server = Config.ServerName,
        evasions = 0,
    }
    index(ban)
    Rempart.Storage.bans.save(ban)
    return ban
end

function Bans.remove(id)
    local ban = bans[id]
    if not ban then return false end
    unindex(ban)
    Rempart.Storage.bans.delete(id)
    return true
end

function Bans.get(id)
    return bans[id]
end

--- Cherche un ban actif correspondant aux identifiants/tokens fournis.
--- @return table|nil ban, string|nil 'identifier'|'token'
function Bans.match(identifiers, tokens)
    local function check(banId)
        local ban = bans[banId]
        if not ban then return nil end
        if isExpired(ban) then
            Bans.remove(ban.id)
            return nil
        end
        return ban
    end
    for _, id in ipairs(identifiers or {}) do
        local banId = idIndex[id]
        if banId then
            local ban = check(banId)
            if ban then return ban, 'identifier' end
        end
    end
    if Config.Bans.useTokens then
        for _, t in ipairs(tokens or {}) do
            local banId = tokenIndex[t]
            if banId then
                local ban = check(banId)
                if ban then return ban, 'token' end
            end
        end
    end
    return nil
end

--- Étend un ban avec de nouveaux identifiants/tokens (contournement détecté).
--- Retourne le nombre d'éléments ajoutés.
function Bans.extend(ban, identifiers, tokens)
    local known = {}
    for _, v in ipairs(ban.identifiers) do known[v] = true end
    for _, v in ipairs(ban.tokens) do known[v] = true end
    local added = 0
    for _, v in ipairs(identifiers or {}) do
        if not known[v] and shouldIndex(v) then
            ban.identifiers[#ban.identifiers + 1] = v
            known[v] = true
            added = added + 1
        end
    end
    if Config.Bans.useTokens then
        for _, v in ipairs(tokens or {}) do
            if not known[v] then
                ban.tokens[#ban.tokens + 1] = v
                known[v] = true
                added = added + 1
            end
        end
    end
    ban.evasions = (ban.evasions or 0) + 1
    index(ban)
    Rempart.Storage.bans.save(ban)
    return added
end

--- Recherche texte (id, nom, identifiant). Résultats triés du plus récent au plus ancien.
function Bans.search(text, limit)
    text = (text or ''):lower()
    local out = {}
    for _, ban in pairs(bans) do
        local hit = text == '' or ban.id:lower() == text or (ban.name or ''):lower():find(text, 1, true)
        if not hit then
            for _, id in ipairs(ban.identifiers) do
                if id:lower():find(text, 1, true) then hit = true break end
            end
        end
        if hit then out[#out + 1] = ban end
    end
    table.sort(out, function(a, b) return (a.createdAt or 0) > (b.createdAt or 0) end)
    if limit and #out > limit then
        for i = #out, limit + 1, -1 do out[i] = nil end
    end
    return out
end

function Bans.count()
    return Utils.count(bans)
end

--- Texte d'expiration lisible.
function Bans.expiryText(ban)
    if (ban.expiresAt or 0) == 0 then return L('expires_never') end
    local left = ban.expiresAt - os.time()
    return ('%s (%s)'):format(os.date('%d/%m/%Y %H:%M', ban.expiresAt), Utils.formatDuration(left, Config.Locale))
end

--- Message affiché au joueur banni.
function Bans.message(ban)
    return L('banned', Config.ServerName, ban.reason, Bans.expiryText(ban), ban.id, Config.AppealUrl)
end

-- Synchronisation multi-serveurs (oxmysql) : rechargement périodique.
CreateThread(function()
    while true do
        Wait(math.max(15, Config.Bans.syncInterval or 60) * 1000)
        if Rempart.Storage.backend == 'oxmysql' then
            Bans.load()
        end
    end
end)
