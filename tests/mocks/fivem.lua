--[[
    Simulateur FXServer minimal pour les tests de scénarios de Rempart.

    • Monde virtuel : joueurs, peds, véhicules, objets, ressources, convars, ACE.
    • Ordonnanceur coopératif à temps virtuel : CreateThread / Wait / SetTimeout / promise.
    • Événements : AddEventHandler / RegisterNetEvent / TriggerEvent avec CancelEvent et `source`.
    • Captures : DropPlayer, TriggerClientEvent, PerformHttpRequest, DeleteEntity, CancelEvent…

    Usage :
        local F = dofile('tests/mocks/fivem.lua')
        local env = F.new({ resource = 'rempart' })
        env:loadManifest('[rempart]/rempart', 'server')
        env:advance(5000)
]]

package.path = 'tests/lib/?.lua;' .. package.path
local dkjson = require('dkjson')

local F = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- vector3
-- ─────────────────────────────────────────────────────────────────────────────

local vmt = {}
vmt.__index = vmt
local function vector3(x, y, z) return setmetatable({ x = x or 0.0, y = y or 0.0, z = z or 0.0 }, vmt) end
vmt.__sub = function(a, b) return vector3(a.x - b.x, a.y - b.y, a.z - b.z) end
vmt.__add = function(a, b) return vector3(a.x + b.x, a.y + b.y, a.z + b.z) end
vmt.__len = function(a) return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z) end
vmt.__tostring = function(a) return ('vector3(%.2f, %.2f, %.2f)'):format(a.x, a.y, a.z) end
F.vector3 = vector3

-- ─────────────────────────────────────────────────────────────────────────────
-- Monde virtuel
-- ─────────────────────────────────────────────────────────────────────────────

local function deepcopy(t)
    if type(t) ~= 'table' then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return setmetatable(o, getmetatable(t))
end

local Env = {}
Env.__index = Env

function F.new(opts)
    opts = opts or {}
    local env = setmetatable({}, Env)
    env.resource = opts.resource or 'rempart'
    env.now = 0
    env.threads = {}           -- { co, wake }
    env.handlers = {}          -- name -> list of { fn, net }
    env.netSafe = {}           -- name -> true
    env.dropped = {}           -- { src, reason }
    env.clientEvents = {}      -- { name, target, args }
    env.http = {}              -- requêtes capturées
    env.deleted = {}           -- handles supprimés
    env.canceled = {}          -- noms d'événements annulés
    env.logs = {}
    env.kvp = {}
    env.convars = opts.convars or { onesync = 'on' }
    env.aces = {}              -- principal -> { [object] = true }
    env.playerAce = {}         -- src -> { [object] = true }
    env.players = {}           -- src -> { name, ids, tokens, ped, bucket, flags… }
    env.entities = {}          -- handle -> entité
    env.netIds = {}            -- netId -> handle
    env.nextHandle = 1000
    env.resources = opts.resources or {}   -- nom -> { state, meta = { key = {…} }, files = { path = content } }
    env.resources[env.resource] = env.resources[env.resource] or { state = 'started', meta = {}, files = {} }
    env.exportsTable = {}      -- res -> name -> fn
    env.commands = {}
    env.G = env:makeGlobals()
    return env
end

function Env:spawnEntity(e)
    self.nextHandle = self.nextHandle + 1
    local h = self.nextHandle
    e.handle = h
    e.netId = e.netId or (h - 900)
    e.pos = e.pos or vector3(0, 0, 0)
    e.heading = e.heading or 0.0
    e.pop = e.pop or 7
    e.health = e.health or 200
    e.visible = e.visible ~= false
    self.entities[h] = e
    self.netIds[e.netId] = h
    return h
end

--- Ajoute un joueur connecté (avec ped). Retourne src.
function Env:addPlayer(src, data)
    data = data or {}
    local ped = self:spawnEntity({ type = 1, netType = 11, model = data.model or 0x705E61F2, owner = src,
        firstOwner = src, pos = data.pos or vector3(0, 0, 70), heading = data.heading or 0.0, isPlayer = true,
        pop = 6, health = data.health or 200 })
    self.players[src] = {
        name = data.name or ('Joueur' .. src),
        ids = data.ids or { 'license:lic' .. src, 'license2:lic2' .. src, 'discord:' .. (1000 + src), 'fivem:' .. src, 'ip:10.0.0.' .. src },
        tokens = data.tokens or { '2:tok' .. src .. 'a', '3:tok' .. src .. 'b' },
        ped = ped, bucket = 0, invincible = false, superJump = false, dmgMod = 1.0, meleeMod = 1.0,
        defMod = 1.0, maxHealth = 200, maxArmour = 100, armour = 0, freecam = false, focus = nil,
        weapon = 0xA2719263, airDrag = 1.0,
    }
    self.playerAce[src] = data.ace or {}
    return src
end

function Env:ped(src) return self.players[src].ped end
function Env:entity(h) return self.entities[h] end

-- ─────────────────────────────────────────────────────────────────────────────
-- Ordonnanceur
-- ─────────────────────────────────────────────────────────────────────────────

function Env:spawnThread(fn, ...)
    local args = table.pack(...)
    local co = coroutine.create(function() return fn(table.unpack(args, 1, args.n)) end)
    local t = { co = co, wake = self.now }
    self:resume(t)
    if coroutine.status(co) ~= 'dead' then self.threads[#self.threads + 1] = t end
end

function Env:resume(t)
    local prevSource = self.G.source
    local ok, ms = coroutine.resume(t.co)
    if not ok then
        error(debug.traceback(t.co, tostring(ms)), 0)
    end
    self.G.source = prevSource
    t.wake = self.now + (tonumber(ms) or 0)
end

--- Avance le temps virtuel de `ms`, en exécutant les threads dus dans l'ordre.
function Env:advance(ms)
    local target = self.now + ms
    for _ = 1, 1000000 do
        local nextT, nextWake = nil, math.huge
        for _, t in ipairs(self.threads) do
            if t.wake < nextWake then nextT, nextWake = t, t.wake end
        end
        if not nextT or nextWake > target then break end
        if nextWake > self.now then self.now = nextWake end
        self:resume(nextT)
        if coroutine.status(nextT.co) == 'dead' then
            for i, t in ipairs(self.threads) do
                if t == nextT then table.remove(self.threads, i) break end
            end
        end
    end
    self.now = target
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Événements
-- ─────────────────────────────────────────────────────────────────────────────

--- Déclenche un événement. source : '' (local), number (réseau 'net:N') ou 'internal:N'.
--- Retourne true si l'événement a été annulé.
function Env:trigger(name, source, ...)
    local list = self.handlers[name]
    local canceled = false
    if not list then return false end
    local isNet = type(source) == 'number'
    if isNet and not self.netSafe[name] then return false end
    local src = source
    if type(source) == 'string' and source:match('^internal:') then src = tonumber(source:sub(10)) end
    local frame = { canceled = false }
    local prevFrame = self.frame
    self.frame = frame
    for _, h in ipairs(list) do
        local args = table.pack(...)
        self:spawnThread(function()
            self.G.source = src
            return h(table.unpack(args, 1, args.n))
        end)
    end
    self.frame = prevFrame
    canceled = frame.canceled
    if canceled then self.canceled[#self.canceled + 1] = name end
    return canceled
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Globales FiveM simulées
-- ─────────────────────────────────────────────────────────────────────────────

function Env:makeGlobals()
    local env = self
    local G = setmetatable({}, { __index = _G })
    G._G = G

    -- JSON / msgpack
    G.json = {
        encode = function(v) return dkjson.encode(v) end,
        decode = function(s) local v = dkjson.decode(s) return v end,
    }
    local packed = {}
    G.msgpack = {
        pack_args = function(...) local key = ('<payload#%d>'):format(#packed + 1) packed[key] = table.pack(...) return key end,
        unpack = function(s) return packed[s] end,
    }
    env.packed = packed
    G.vector3, G.vec3 = vector3, vector3

    -- Ordonnancement
    G.Wait = function(ms) coroutine.yield(ms or 0) end
    G.CreateThread = function(fn) env:spawnThread(fn) end
    G.SetTimeout = function(ms, fn) env:spawnThread(function() coroutine.yield(ms) fn() end) end
    G.Citizen = {
        CreateThread = G.CreateThread, Wait = G.Wait, SetTimeout = G.SetTimeout,
        Await = function(p)
            while p.state == 0 do coroutine.yield(10) end
            return p.value
        end,
    }
    G.promise = {
        new = function()
            local p = { state = 0 }
            function p:resolve(v) self.state, self.value = 1, v end
            function p:reject(v) self.state, self.value = 2, v end
            return p
        end,
    }

    -- Événements
    G.AddEventHandler = function(name, fn)
        env.handlers[name] = env.handlers[name] or {}
        table.insert(env.handlers[name], fn)
        return { name = name, fn = fn }
    end
    G.RegisterNetEvent = function(name, fn)
        env.netSafe[name] = true
        if fn then return G.AddEventHandler(name, fn) end
    end
    G.RegisterServerEvent = G.RegisterNetEvent
    G.TriggerEvent = function(name, ...) return env:trigger(name, '', ...) end
    G.CancelEvent = function() if env.frame then env.frame.canceled = true end end
    G.TriggerClientEvent = function(name, target, ...)
        env.clientEvents[#env.clientEvents + 1] = { name = name, target = target, args = table.pack(...) }
    end
    G.RegisterCommand = function(name, fn) env.commands[name] = fn end
    G.GetInvokingResource = function() return 'test' end

    -- Exports
    G.exports = setmetatable({}, {
        __call = function(_, name, fn)
            env.exportsTable[env.resource] = env.exportsTable[env.resource] or {}
            env.exportsTable[env.resource][name] = fn
        end,
        __index = function(_, res)
            return setmetatable({}, { __index = function(_, name)
                local fn = env.exportsTable[res] and env.exportsTable[res][name]
                if not fn then error(('No such export %s in resource %s'):format(name, res)) end
                return function(_, ...) return fn(...) end
            end })
        end,
    })

    -- Ressources / convars / ACE
    G.GetCurrentResourceName = function() return env.resource end
    G.IsDuplicityVersion = function() return true end
    G.GetConvar = function(k, d) local v = env.convars[k] if v == nil then return d end return tostring(v) end
    G.GetConvarInt = function(k, d) return tonumber(env.convars[k]) or d end
    G.SetConvar = function(k, v) env.convars[k] = v end
    G.SetConvarReplicated = G.SetConvar
    G.GetResourceState = function(res)
        local r = env.resources[res]
        return r and r.state or 'missing'
    end
    local function resList()
        local l = {}
        for name in pairs(env.resources) do l[#l + 1] = name end
        table.sort(l)
        return l
    end
    G.GetNumResources = function() return #resList() end
    G.GetResourceByFindIndex = function(i) return resList()[i + 1] end
    G.GetNumResourceMetadata = function(res, key)
        local r = env.resources[res]
        return r and r.meta and r.meta[key] and #r.meta[key] or 0
    end
    G.GetResourceMetadata = function(res, key, i)
        local r = env.resources[res]
        return r and r.meta and r.meta[key] and r.meta[key][i + 1] or nil
    end
    G.LoadResourceFile = function(res, path)
        local r = env.resources[res]
        return r and r.files and r.files[path] or nil
    end
    G.GetResourcePath = function(res) return '/virtual/' .. res end
    G.IsPlayerAceAllowed = function(src, obj)
        local a = env.playerAce[tonumber(src)]
        return (a and a[obj]) and true or false
    end
    G.IsPrincipalAceAllowed = function(principal, obj)
        local a = env.aces[principal]
        return (a and a[obj]) and true or false
    end

    -- KVP
    G.SetResourceKvp = function(k, v) env.kvp[k] = v end
    G.GetResourceKvpString = function(k) return env.kvp[k] end
    G.DeleteResourceKvp = function(k) env.kvp[k] = nil end
    local finds = {}
    G.StartFindKvp = function(prefix)
        local keys = {}
        for k in pairs(env.kvp) do if k:sub(1, #prefix) == prefix then keys[#keys + 1] = k end end
        table.sort(keys)
        finds[#finds + 1] = { keys = keys, i = 0 }
        return #finds
    end
    G.FindKvp = function(h) local f = finds[h] f.i = f.i + 1 return f.keys[f.i] end
    G.EndFindKvp = function() end

    -- HTTP
    G.PerformHttpRequest = function(url, cb, method, data, headers)
        env.http[#env.http + 1] = { url = url, method = method, data = data, headers = headers }
        if cb then G.SetTimeout(50, function() cb(204, '', {}) end) end
    end

    -- Temps
    G.GetGameTimer = function() return env.now end

    -- Joueurs
    G.GetPlayers = function()
        local l = {}
        for src in pairs(env.players) do l[#l + 1] = tostring(src) end
        table.sort(l)
        return l
    end
    G.GetPlayerName = function(src) local p = env.players[tonumber(src)] return p and p.name or nil end
    G.GetPlayerIdentifiers = function(src) local p = env.players[tonumber(src)] return p and deepcopy(p.ids) or {} end
    G.GetPlayerTokens = function(src) local p = env.players[tonumber(src)] return p and deepcopy(p.tokens) or {} end
    G.GetPlayerPed = function(src) local p = env.players[tonumber(src)] return p and p.ped or 0 end
    G.GetPlayerRoutingBucket = function(src) local p = env.players[tonumber(src)] return p and p.bucket or 0 end
    G.GetPlayerPing = function() return 40 end
    G.DropPlayer = function(src, reason)
        env.dropped[#env.dropped + 1] = { src = tonumber(src), reason = reason }
        env.players[tonumber(src)] = nil
    end
    G.GetPlayerInvincible = function(src) return env.players[tonumber(src)].invincible end
    G.IsPlayerUsingSuperJump = function(src) return env.players[tonumber(src)].superJump end
    G.GetPlayerWeaponDamageModifier = function(src) return env.players[tonumber(src)].dmgMod end
    G.GetPlayerMeleeWeaponDamageModifier = function(src) return env.players[tonumber(src)].meleeMod end
    G.GetPlayerWeaponDefenseModifier = function(src) return env.players[tonumber(src)].defMod end
    G.GetPlayerMaxHealth = function(src) return env.players[tonumber(src)].maxHealth end
    G.GetPlayerMaxArmour = function(src) return env.players[tonumber(src)].maxArmour end
    G.IsPlayerInFreeCamMode = function(src) return env.players[tonumber(src)].freecam end
    G.GetPlayerFocusPos = function(src)
        local p = env.players[tonumber(src)]
        return p.focus or env.entities[p.ped].pos
    end
    G.GetAirDragMultiplierForPlayersVehicle = function(src) return env.players[tonumber(src)].airDrag end

    -- Entités
    local function E(h) return env.entities[h] end
    G.DoesEntityExist = function(h) return E(h) ~= nil end
    G.DeleteEntity = function(h) env.deleted[#env.deleted + 1] = h env.entities[h] = nil end
    G.GetEntityCoords = function(h) local e = E(h) return e and vector3(e.pos.x, e.pos.y, e.pos.z) or vector3() end
    G.GetEntityHeading = function(h) return E(h).heading end
    G.GetEntityModel = function(h) return E(h).model end
    G.GetEntityType = function(h) local e = E(h) return e and e.type or 0 end
    G.GetNetTypeFromEntity = function(h) local e = E(h) return e and (e.netType or ({ 6, 0, 5 })[e.type]) or -1 end
    G.GetEntityPopulationType = function(h) local e = E(h) return e and e.pop or 0 end
    G.GetEntityScript = function(h) local e = E(h) return e and e.script or nil end
    G.NetworkGetFirstEntityOwner = function(h) local e = E(h) return e and (e.firstOwner or e.owner) or -1 end
    G.NetworkGetEntityOwner = function(h) local e = E(h) return e and e.owner or -1 end
    G.NetworkGetEntityFromNetworkId = function(id) return env.netIds[id] or 0 end
    G.NetworkGetNetworkIdFromEntity = function(h) local e = E(h) return e and e.netId or 0 end
    G.GetEntityAttachedTo = function(h) local e = E(h) return e and e.attachedTo or 0 end
    G.IsPedAPlayer = function(h) local e = E(h) return e and e.isPlayer == true end
    G.GetEntityHealth = function(h) local e = E(h) return e and e.health or 0 end
    G.GetPedArmour = function(h)
        for _, p in pairs(env.players) do if p.ped == h then return p.armour end end
        return 0
    end
    G.IsEntityVisible = function(h) return E(h).visible end
    G.GetEntityCollisionDisabled = function(h) return E(h).noCollision == true end
    G.IsEntityPositionFrozen = function(h) return E(h).frozen == true end
    G.IsPedRagdoll = function(h) return E(h).ragdoll == true end
    G.GetVehiclePedIsIn = function(h) local e = E(h) return e and e.vehicle or 0 end
    G.GetPedInVehicleSeat = function(veh) local e = E(veh) return e and e.driver or 0 end
    G.GetVehicleType = function(veh) local e = E(veh) return e and e.vehicleType or 'automobile' end
    G.GetVehicleEngineHealth = function(veh) return E(veh).engineHealth or 1000.0 end
    G.GetVehicleBodyHealth = function(veh) return E(veh).bodyHealth or 1000.0 end
    G.GetVehicleTotalRepairs = function(veh) return E(veh).repairs or 0 end
    G.GetSelectedPedWeapon = function(ped)
        for _, p in pairs(env.players) do if p.ped == ped then return p.weapon end end
        return 0
    end
    G.RemoveWeaponFromPed = function(ped, w)
        for _, p in pairs(env.players) do if p.ped == ped and p.weapon == w then p.weapon = 0xA2719263 end end
    end

    -- Divers
    G.GetHashKey = function(s) return env.joaat(s) end
    G.os = setmetatable({ nanotime = function() return env.now * 1000000 end }, { __index = os })
    G.io = setmetatable({
        open = function() return nil end,  -- journal fichier désactivé en test
        readdir = function(path)
            local res, rel = path:match('^/virtual/([^/]+)/?(.*)$')
            local r = res and env.resources[res]
            if not r then return nil end
            local names, seen = {}, {}
            local prefix = rel == '' and '' or (rel .. '/')
            local isDir = false
            for file in pairs(r.files or {}) do
                if file:sub(1, #prefix) == prefix then
                    isDir = true
                    local rest = file:sub(#prefix + 1)
                    local first = rest:match('^([^/]+)')
                    if first and not seen[first] then seen[first] = true names[#names + 1] = first end
                end
            end
            if not isDir then return nil end
            local i = 0
            return { lines = function() return function() i = i + 1 return names[i] end end, close = function() end }
        end,
    }, { __index = io })
    G.print = function(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        env.logs[#env.logs + 1] = table.concat(parts, ' ')
        if os.getenv('RMP_VERBOSE') then print(...) end
    end
    return G
end

F.Env = Env

--- joaat (identique à GetHashKey)
function Env.joaat(s)
    s = tostring(s):lower()
    local h = 0
    for i = 1, #s do
        h = (h + s:byte(i)) & 0xFFFFFFFF
        h = (h + (h << 10)) & 0xFFFFFFFF
        h = h ~ (h >> 6)
    end
    h = (h + (h << 3)) & 0xFFFFFFFF
    h = h ~ (h >> 11)
    h = (h + (h << 15)) & 0xFFFFFFFF
    return h
end

--- Charge un fichier Lua dans l'environnement simulé.
function Env:load(path)
    local chunk, err = loadfile(path, 't', self.G)
    if not chunk then error(err) end
    self:spawnThread(chunk)
end

local function listGlob(dir, pattern)
    local out = {}
    local p = io.popen(('ls -1 "%s/%s" 2>/dev/null'):format(dir, pattern:gsub('/[^/]*$', '')))
    if p then
        local fileGlob = pattern:match('([^/]*)$'):gsub('%.', '%%.'):gsub('%*', '.*')
        local sub = pattern:match('^(.*)/[^/]*$') or ''
        for name in p:lines() do
            if name:match('^' .. fileGlob .. '$') then out[#out + 1] = (sub ~= '' and (sub .. '/') or '') .. name end
        end
        p:close()
    end
    table.sort(out)
    return out
end

--- Charge les scripts d'un fxmanifest (side = 'server' | 'client') dans l'ordre déclaré.
function Env:loadManifest(dir, side)
    local manifest = { shared = {}, server = {}, client = {} }
    local menv = setmetatable({}, { __index = function(_, k)
        return function(v)
            if k == 'shared_scripts' or k == 'shared_script' then
                for _, f in ipairs(type(v) == 'table' and v or { v }) do manifest.shared[#manifest.shared + 1] = f end
            elseif k == 'server_scripts' or k == 'server_script' then
                for _, f in ipairs(type(v) == 'table' and v or { v }) do manifest.server[#manifest.server + 1] = f end
            elseif k == 'client_scripts' or k == 'client_script' then
                for _, f in ipairs(type(v) == 'table' and v or { v }) do manifest.client[#manifest.client + 1] = f end
            end
        end
    end })
    local chunk = assert(loadfile(dir .. '/fxmanifest.lua', 't', menv))
    chunk()
    local files = {}
    for _, f in ipairs(manifest.shared) do files[#files + 1] = f end
    for _, f in ipairs(manifest[side]) do files[#files + 1] = f end
    for _, f in ipairs(files) do
        if f:find('%*') then
            for _, g in ipairs(listGlob(dir, f)) do self:load(dir .. '/' .. g) end
        else
            self:load(dir .. '/' .. f)
        end
    end
end

return F
