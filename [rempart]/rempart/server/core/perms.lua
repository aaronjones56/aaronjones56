--[[
    Rempart — permissions (ACE), admins txAdmin, exemptions temporaires.
]]

local Perms = {}
Rempart.Perms = Perms

local P_ADMIN = Config.Permissions.admin
local P_BYPASS = Config.Permissions.bypass
local P_PREFIX = Config.Permissions.bypassPrefix

local txAdmins = {}      -- src -> true (admins txAdmin authentifiés en jeu)
local aceCache = {}      -- src -> { [ace] = { value, expires } }

local function ace(src, object)
    local now = Rempart.now()
    local c = aceCache[src]
    if not c then
        c = {}
        aceCache[src] = c
    end
    local e = c[object]
    if e and e[2] > now then return e[1] end
    local v = IsPlayerAceAllowed(src, object) and true or false
    c[object] = { v, now + 30000 }
    return v
end

function Perms.refresh(P)
    aceCache[P.src] = nil
    P.admin = ace(P.src, P_ADMIN)
    P.bypass = ace(P.src, P_BYPASS)
    P.txAdmin = txAdmins[P.src] == true
end

function Perms.isAdmin(src)
    if src == 0 then return true end -- console
    return ace(src, P_ADMIN) or (Config.Permissions.txAdminBypass and txAdmins[src] == true)
end

--- Le joueur est-il immunisé contre cette détection ?
function Perms.immune(P, def)
    if P.bypass then return true end
    if Config.Permissions.txAdminBypass and P.txAdmin then return true end
    if ace(P.src, P_PREFIX .. def.id) or ace(P.src, P_PREFIX .. def.category) then return true end
    return Perms.isExempt(P, def)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Exemptions temporaires (API, commandes, intégrations)
-- ─────────────────────────────────────────────────────────────────────────────

--- `key` = id de détection, catégorie, ou 'all'.
function Perms.exempt(P, key, seconds)
    P.exempt[key] = Rempart.now() + math.floor((seconds or 10) * 1000)
end

function Perms.isExempt(P, def)
    local now, ex = Rempart.now(), P.exempt
    local function active(k)
        local t = ex[k]
        if t and t > now then return true end
        if t then ex[k] = nil end
        return false
    end
    return active('all') or active(def.id) or active(def.category)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Intégration txAdmin (événements serveur-locaux émis par la ressource monitor)
-- ─────────────────────────────────────────────────────────────────────────────

AddEventHandler('txAdmin:events:adminAuth', function(data)
    if type(data) ~= 'table' then return end
    local src = tonumber(data.netid)
    if not src or src < 0 then return end
    txAdmins[src] = data.isAdmin == true or nil
    local P = Rempart.Players.get(src)
    if P then P.txAdmin = txAdmins[src] == true end
end)

AddEventHandler('txAdmin:events:adminsUpdated', function(list)
    if type(list) ~= 'table' then return end
    txAdmins = {}
    for _, id in ipairs(list) do
        local src = tonumber(id)
        if src then txAdmins[src] = true end
    end
    for src, P in Rempart.Players.each() do
        P.txAdmin = txAdmins[src] == true
    end
end)

-- Soin txAdmin : la santé remonte brutalement, on évite un faux positif.
AddEventHandler('txAdmin:events:playerHealed', function(data)
    local target = type(data) == 'table' and tonumber(data.target) or nil
    if not target then return end
    for src, P in Rempart.Players.each() do
        if target == -1 or target == src then
            Perms.exempt(P, 'state', 10)
        end
    end
end)

AddEventHandler('playerDropped', function()
    local src = tonumber(source)
    if src then
        aceCache[src] = nil
        txAdmins[src] = nil
    end
end)

-- Les ACE peuvent changer en cours de partie (add_principal dynamique des frameworks).
CreateThread(function()
    while true do
        Wait(60000)
        for _, P in Rempart.Players.each() do
            Perms.refresh(P)
        end
    end
end)
