--[[
    Rempart — API publique (exports serveur).

    local AC = exports[GetConvar('rempart:resource', 'rempart')]
    AC:Flag(source, 'money_exploit', { montant = 1e9 }, 80)   -- détection personnalisée
    AC:AllowTeleport(source, vector3(x, y, z))                 -- téléportation légitime à venir
    AC:Exempt(source, 'noclip', 30)                            -- exemption temporaire (s)
    AC:Ban(source, 'Raison', 0)                                -- 0 = définitif
]]

local function P(src) return Rempart.Players.ensure(tonumber(src)) end

--- Détection personnalisée. `id` peut être un identifiant du catalogue ou un libellé libre.
exports('Flag', function(src, id, details, score)
    local d = type(details) == 'table' and details or { info = tostring(details or '') }
    if Rempart.Detections[id] then
        return Rempart.Detect(src, id, d, { score = score })
    end
    d.detection = tostring(id)
    return Rempart.Detect(src, 'custom', d, { score = score, reason = tostring(id) })
end)

exports('Ban', function(src, reason, duration, by)
    local p = P(src)
    if not p then return false end
    Rempart.Punish.ban(p, { reason = reason, duration = tonumber(duration) or 0, by = by or GetInvokingResource(), screenshot = false })
    local ban = Rempart.Bans.match(p.idList, p.tokens)
    return ban and ban.id or false
end)

exports('BanIdentifier', function(identifier, reason, duration, by)
    if type(identifier) ~= 'string' or not identifier:find(':') then return false end
    local ban = Rempart.Bans.add({ name = '(hors ligne)', reason = reason, identifiers = { identifier },
        duration = tonumber(duration) or 0, by = by or GetInvokingResource() })
    return ban.id
end)

exports('Unban', function(query)
    local ban = Rempart.Bans.get(query) or Rempart.Bans.match({ query }, { query })
    return ban and Rempart.Bans.remove(ban.id) or false
end)

--- Retourne l'enregistrement de ban correspondant (identifiants et/ou tokens) ou false.
exports('IsBanned', function(identifiers, tokens)
    if type(identifiers) == 'string' then identifiers = { identifiers } end
    local ban = Rempart.Bans.match(identifiers or {}, tokens or {})
    return ban or false
end)

exports('Kick', function(src, reason)
    local p = P(src)
    if not p then return false end
    Rempart.Punish.kick(p, reason, { by = GetInvokingResource() })
    return true
end)

exports('Exempt', function(src, key, seconds)
    local p = P(src)
    if not p then return false end
    Rempart.Perms.exempt(p, key or 'all', tonumber(seconds) or 10)
    return true
end)

exports('AllowTeleport', function(src, coords, ms)
    local p = P(src)
    if not p then return false end
    local c = coords and { x = coords.x, y = coords.y, z = coords.z } or nil
    Rempart.Movement.expect(p.src, c, tonumber(ms) or 10000)
    return true
end)

--- Déclaration côté serveur d'un état légitime ('invisible', 'invincible', 'collision', 'frozen', 'camera'…).
exports('Declare', function(src, kind, value)
    local p = P(src)
    if not p or type(kind) ~= 'string' then return false end
    p.decl.flags[kind] = { v = value ~= false, r = GetInvokingResource() or 'serveur', t = Rempart.now() }
    return true
end)

exports('SetBypass', function(src, enabled)
    local p = P(src)
    if not p then return false end
    p.bypass = enabled == true
    return true
end)

exports('GetRisk', function(src)
    local p = Rempart.Players.get(src)
    return p and Rempart.Punish.currentScore(p) or 0
end)

exports('GetHistory', function(src)
    local p = Rempart.Players.get(src)
    return p and p.hist:list() or {}
end)

exports('IsAuditMode', function() return Config.AuditMode == true end)
