--[[
    Rempart — utilitaires partagés (client + serveur).
    Aucune dépendance aux natives : testable hors FiveM (voir tests/).
]]

Utils = {}

local floor, sqrt, abs, atan, deg, rad, sin, cos, huge = math.floor, math.sqrt, math.abs, math.atan, math.deg, math.rad, math.sin, math.cos, math.huge
local tointeger = math.tointeger
local sformat, sbyte, schar, ssub, sgsub, slower = string.format, string.byte, string.char, string.sub, string.gsub, string.lower
local tconcat, tinsert, tremove = table.concat, table.insert, table.remove

-- ─────────────────────────────────────────────────────────────────────────────
-- Nombres & hashes
-- ─────────────────────────────────────────────────────────────────────────────

function Utils.isNaN(v) return v ~= v end

function Utils.isFinite(v)
    return type(v) == 'number' and v == v and v ~= huge and v ~= -huge
end

function Utils.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function Utils.round(v, decimals)
    local m = 10 ^ (decimals or 0)
    return floor(v * m + 0.5) / m
end

--- Normalise un hash (signé ou non, entier ou flottant entier) en entier non signé 32 bits.
function Utils.h32(v)
    if type(v) == 'string' then
        return Utils.joaat(v)
    end
    if type(v) ~= 'number' then return 0 end
    local i = tointeger(v)
    if not i then
        i = floor(v)
        i = tointeger(i) or 0
    end
    return i & 0xFFFFFFFF
end

--- Hash Jenkins one-at-a-time (identique à GetHashKey, insensible à la casse).
function Utils.joaat(str)
    str = slower(tostring(str))
    local h = 0
    for i = 1, #str do
        h = (h + sbyte(str, i)) & 0xFFFFFFFF
        h = (h + (h << 10)) & 0xFFFFFFFF
        h = h ~ (h >> 6)
    end
    h = (h + (h << 3)) & 0xFFFFFFFF
    h = h ~ (h >> 11)
    h = (h + (h << 15)) & 0xFFFFFFFF
    return h
end

--- Construit un ensemble { [hash32] = nom } à partir d'une liste de noms ou de hashes.
function Utils.hashSet(list)
    local set = {}
    for _, v in ipairs(list or {}) do
        if type(v) == 'string' then
            set[Utils.joaat(v)] = v
        elseif type(v) == 'number' then
            set[Utils.h32(v)] = tostring(v)
        end
    end
    return set
end

--- Ensemble { [chaine] = true } (option : insensible à la casse).
function Utils.set(list, lower)
    local s = {}
    for _, v in ipairs(list or {}) do
        if type(v) == 'string' then
            s[lower and slower(v) or v] = true
        else
            s[v] = true
        end
    end
    return s
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Chaînes
-- ─────────────────────────────────────────────────────────────────────────────

function Utils.trim(s)
    return (sgsub(tostring(s or ''), '^%s*(.-)%s*$', '%1'))
end

function Utils.startsWith(s, prefix)
    return type(s) == 'string' and ssub(s, 1, #prefix) == prefix
end

function Utils.split(s, sep)
    local out = {}
    sep = sep or '%s'
    for part in string.gmatch(tostring(s), '([^' .. sep .. ']+)') do
        out[#out + 1] = part
    end
    return out
end

function Utils.truncate(s, max)
    s = tostring(s or '')
    if #s <= max then return s end
    return ssub(s, 1, math.max(0, max - 3)) .. '...'
end

--- Supprime les codes couleur FiveM (^0-^9) et les caractères de contrôle.
function Utils.stripColors(s)
    s = sgsub(tostring(s or ''), '%^%d', '')
    s = sgsub(s, '[%c]', '')
    return s
end

--- Échappe le markdown Discord.
function Utils.escapeMarkdown(s)
    return (sgsub(tostring(s or ''), '([%*_~`|>\\])', '\\%1'))
end

function Utils.randomHex(n)
    local out = {}
    for i = 1, n do
        out[i] = sformat('%x', math.random(0, 15))
    end
    return tconcat(out)
end

local B32 = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789' -- sans I, O, 0, 1 (lisibilité)
function Utils.randomCode(n)
    local out = {}
    for i = 1, n do
        local idx = math.random(1, #B32)
        out[i] = ssub(B32, idx, idx)
    end
    return tconcat(out)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Base64 (pour les captures d'écran)
-- ─────────────────────────────────────────────────────────────────────────────

local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local B64INV = {}
for i = 1, 64 do B64INV[sbyte(B64, i)] = i - 1 end

function Utils.base64Decode(data)
    data = sgsub(data, '[^%w%+/=]', '')
    local out, n = {}, 0
    local bits, nbits = 0, 0
    for i = 1, #data do
        local c = sbyte(data, i)
        if c == 61 then break end -- '='
        local v = B64INV[c]
        if v then
            bits = (bits << 6) | v
            nbits = nbits + 6
            if nbits >= 8 then
                nbits = nbits - 8
                n = n + 1
                out[n] = schar((bits >> nbits) & 0xFF)
            end
        end
    end
    return tconcat(out)
end

function Utils.base64Encode(data)
    local out = {}
    local len = #data
    for i = 1, len, 3 do
        local a, b, c = sbyte(data, i, i + 2)
        local v = (a << 16) | ((b or 0) << 8) | (c or 0)
        local i1 = (v >> 18) & 63
        local i2 = (v >> 12) & 63
        local i3 = (v >> 6) & 63
        local i4 = v & 63
        out[#out + 1] = ssub(B64, i1 + 1, i1 + 1) .. ssub(B64, i2 + 1, i2 + 1)
            .. (b and ssub(B64, i3 + 1, i3 + 1) or '=') .. (c and ssub(B64, i4 + 1, i4 + 1) or '=')
    end
    return tconcat(out)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Tables
-- ─────────────────────────────────────────────────────────────────────────────

function Utils.count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

function Utils.deepCopy(v, seen)
    if type(v) ~= 'table' then return v end
    seen = seen or {}
    if seen[v] then return seen[v] end
    local out = {}
    seen[v] = out
    for k, x in pairs(v) do
        out[Utils.deepCopy(k, seen)] = Utils.deepCopy(x, seen)
    end
    return out
end

--- Fusion profonde : les valeurs de `over` écrasent celles de `base` (tableaux remplacés en bloc).
function Utils.merge(base, over)
    if type(over) ~= 'table' then return base end
    for k, v in pairs(over) do
        if type(v) == 'table' and type(base[k]) == 'table' and #v == 0 and next(v) ~= nil then
            Utils.merge(base[k], v)
        else
            base[k] = v
        end
    end
    return base
end

function Utils.keys(t)
    local out = {}
    for k in pairs(t or {}) do out[#out + 1] = k end
    table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
    return out
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Inspection d'arguments (anti-payloads malformés)
-- ─────────────────────────────────────────────────────────────────────────────

--- Vérifie récursivement une valeur : NaN/infini, chaînes géantes, tables trop profondes/larges.
--- @return boolean ok, string|nil raison
function Utils.inspectValue(v, limits, depth, budget)
    depth = depth or 0
    budget = budget or { nodes = 0 }
    local tv = type(v)
    if tv == 'number' then
        if v ~= v then return false, 'NaN' end
        if v == huge or v == -huge then return false, 'infini' end
        if limits.maxNumber and abs(v) > limits.maxNumber then return false, 'nombre démesuré' end
    elseif tv == 'string' then
        if #v > limits.maxString then return false, ('chaîne de %d octets'):format(#v) end
    elseif tv == 'table' then
        if depth >= limits.maxDepth then return false, 'profondeur excessive' end
        for k, x in pairs(v) do
            budget.nodes = budget.nodes + 1
            if budget.nodes > limits.maxNodes then return false, 'table trop volumineuse' end
            local ok, why = Utils.inspectValue(k, limits, depth + 1, budget)
            if not ok then return false, why end
            ok, why = Utils.inspectValue(x, limits, depth + 1, budget)
            if not ok then return false, why end
        end
    end
    return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Géométrie (convention GTA : cap 0° = +Y, sens anti-horaire)
-- ─────────────────────────────────────────────────────────────────────────────

function Utils.dist3(ax, ay, az, bx, by, bz)
    local dx, dy, dz = ax - bx, ay - by, az - bz
    return sqrt(dx * dx + dy * dy + dz * dz)
end

function Utils.dist2(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return sqrt(dx * dx + dy * dy)
end

--- Cap GTA (degrés) pointant de (ax,ay) vers (bx,by).
function Utils.bearing(ax, ay, bx, by)
    local h = deg(atan(-(bx - ax), by - ay))
    if h < 0 then h = h + 360.0 end
    return h
end

--- Écart angulaire absolu entre deux caps (0..180).
function Utils.angleDiff(a, b)
    local d = abs((a - b) % 360.0)
    if d > 180.0 then d = 360.0 - d end
    return d
end

function Utils.headingVector(h)
    local r = rad(h)
    return -sin(r), cos(r)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Durées
-- ─────────────────────────────────────────────────────────────────────────────

local UNITS = { s = 1, m = 60, h = 3600, d = 86400, j = 86400, w = 604800, sem = 604800, mo = 2592000, y = 31536000, a = 31536000 }

--- "30m", "12h", "7d"/"7j", "2w", "perm" -> secondes (0 = permanent). nil si invalide.
function Utils.parseDuration(str)
    if str == nil then return nil end
    str = slower(Utils.trim(str))
    if str == '' then return nil end
    if str == 'perm' or str == 'permanent' or str == '0' or str == 'p' then return 0 end
    local total, matched = 0, false
    for num, unit in string.gmatch(str, '(%d+)%s*(%a+)') do
        local mult = UNITS[unit]
        if not mult then return nil end
        total = total + tonumber(num) * mult
        matched = true
    end
    if not matched then
        local n = tonumber(str)
        if n then return floor(n * 60) end -- nombre seul = minutes
        return nil
    end
    return total
end

function Utils.formatDuration(seconds, lang)
    if not seconds or seconds <= 0 then
        return lang == 'en' and 'permanent' or 'définitif'
    end
    local parts = {}
    local d = floor(seconds / 86400); seconds = seconds % 86400
    local h = floor(seconds / 3600); seconds = seconds % 3600
    local m = floor(seconds / 60)
    if d > 0 then parts[#parts + 1] = d .. (lang == 'en' and 'd' or 'j') end
    if h > 0 then parts[#parts + 1] = h .. 'h' end
    if m > 0 and d == 0 then parts[#parts + 1] = m .. 'min' end
    if #parts == 0 then parts[1] = '<1min' end
    return tconcat(parts, ' ')
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Structures de données
-- ─────────────────────────────────────────────────────────────────────────────

--- Seau à jetons : `rate` jetons/s, capacité `burst`.
local TokenBucket = {}
TokenBucket.__index = TokenBucket

function Utils.TokenBucket(rate, burst, now)
    return setmetatable({ rate = rate, burst = burst, tokens = burst, last = now or 0 }, TokenBucket)
end

--- Consomme `cost` jetons ; `now` en millisecondes. Retourne false si le seau est vide.
function TokenBucket:take(now, cost)
    cost = cost or 1
    local elapsed = (now - self.last) / 1000.0
    if elapsed > 0 then
        self.tokens = math.min(self.burst, self.tokens + elapsed * self.rate)
        self.last = now
    end
    if self.tokens >= cost then
        self.tokens = self.tokens - cost
        return true
    end
    return false
end

--- Compteur à fenêtre glissante (horodatages en ms).
local Window = {}
Window.__index = Window

function Utils.Window(spanMs)
    -- head/tail explicites : `#` est indéfini sur une table à trous.
    return setmetatable({ span = spanMs, times = {}, values = {}, head = 1, tail = 0 }, Window)
end

function Window:add(now, value)
    local tail = self.tail + 1
    self.tail = tail
    self.times[tail] = now
    self.values[tail] = value == nil and false or value
    self:prune(now)
    return self.tail - self.head + 1
end

function Window:prune(now)
    local times, values, limit = self.times, self.values, now - self.span
    local head = self.head
    while head <= self.tail and times[head] < limit do
        times[head], values[head] = nil, nil
        head = head + 1
    end
    self.head = head
    if head > self.tail then
        -- fenêtre vide : on repart de zéro (évite la croissance des index)
        self.head, self.tail = 1, 0
    elseif head > 1024 and (self.tail - head) < head / 4 then
        -- compactage : trafic continu, on réindexe pour libérer la mémoire
        local nt, nv, n = {}, {}, 0
        for i = head, self.tail do
            n = n + 1
            nt[n], nv[n] = times[i], values[i]
        end
        self.times, self.values, self.head, self.tail = nt, nv, 1, n
    end
end

function Window:count(now)
    self:prune(now)
    return self.tail - self.head + 1
end

--- Nombre de valeurs distinctes dans la fenêtre.
function Window:distinct(now)
    self:prune(now)
    local seen, n, values = {}, 0, self.values
    for i = self.head, self.tail do
        local v = values[i]
        if v ~= false and not seen[v] then
            seen[v] = true
            n = n + 1
        end
    end
    return n
end

function Window:clear()
    self.times, self.values, self.head, self.tail = {}, {}, 1, 0
end

--- Tampon circulaire de taille fixe.
local Ring = {}
Ring.__index = Ring

function Utils.Ring(size)
    return setmetatable({ size = size, items = {}, pos = 0, n = 0 }, Ring)
end

function Ring:push(v)
    self.pos = (self.pos % self.size) + 1
    self.items[self.pos] = v
    if self.n < self.size then self.n = self.n + 1 end
end

--- Éléments du plus ancien au plus récent.
function Ring:list()
    local out = {}
    if self.n == 0 then return out end
    local start = (self.n < self.size) and 1 or (self.pos % self.size) + 1
    for i = 0, self.n - 1 do
        out[#out + 1] = self.items[((start - 1 + i) % self.size) + 1]
    end
    return out
end

--- Signature d'un message du canal : uniquement des chaînes et entiers (jamais de
--- flottants, dont la précision peut changer au transport msgpack).
function Utils.signature(key, kind, seq, extra)
    return Sha256.hmacHex(key, tostring(kind) .. '|' .. tostring(math.tointeger(seq) or seq) .. '|' .. tostring(extra or ''))
end

-- Utilitaires exposés pour les tests
Utils._units = UNITS
Utils._tinsert, Utils._tremove = tinsert, tremove

return Utils
