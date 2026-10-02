--[[
    Module : effets — particules (ptFxEvent), feux (fireEvent), projectiles
    (startProjectileEvent). 100 % serveur, annulables.
]]

Rempart.module('effects', {})
local cfg = Config.Effects

local ptfxBlacklist = Utils.hashSet(cfg.ptfx.blacklist)
local ptfxAssetBlacklist = Utils.hashSet(cfg.ptfx.blacklistAssets)

local function senderContext(sender, detectionId)
    sender = tonumber(sender)
    local P = sender and Rempart.Players.get(sender)
    if not P or P.punished then return nil end
    if Rempart.Perms.immune(P, Rempart.Detections[detectionId]) then return nil end
    return P
end

local function window(P, key, spanSec)
    local st = P.state
    st[key] = st[key] or Utils.Window(spanSec * 1000)
    return st[key]
end

local function pedCoords(src)
    local ped = GetPlayerPed(src)
    if ped == 0 then return nil end
    return GetEntityCoords(ped), ped
end

local function isOtherPlayerPed(src, netId)
    if not netId or netId == 0 then return nil end
    local ent = NetworkGetEntityFromNetworkId(netId)
    if not ent or ent == 0 or not DoesEntityExist(ent) then return nil end
    if GetEntityType(ent) ~= 1 or not IsPedAPlayer(ent) or ent == GetPlayerPed(src) then return nil end
    return ent
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Particules
-- ─────────────────────────────────────────────────────────────────────────────

AddEventHandler('ptFxEvent', function(sender, data)
    local c = cfg.ptfx
    if not c.enabled or type(data) ~= 'table' then return end
    local P = senderContext(sender, 'ptfx_spam')
    if not P then return end

    local n = window(P, 'ptfx', c.window):add(Rempart.now(), true)
    if n > c.maxPerWindow then
        CancelEvent()
        if n == c.maxPerWindow + 1 or n % 25 == 0 then
            Rempart.Detect(P.src, 'ptfx_spam', { nombre = n, fenetre = c.window .. ' s' })
        end
        return
    end

    local effect, asset = Utils.h32(data.effectHash), Utils.h32(data.assetHash)
    if ptfxBlacklist[effect] or ptfxAssetBlacklist[asset] then
        CancelEvent()
        Rempart.Detect(P.src, 'ptfx_blocked', { effet = ptfxBlacklist[effect] or ('0x%08X'):format(effect),
            asset = ptfxAssetBlacklist[asset] or ('0x%08X'):format(asset) })
        return
    end

    if (data.scale or 1.0) > c.maxScale then
        CancelEvent()
        Rempart.Detect(P.src, 'ptfx_blocked', { echelle = Utils.round(data.scale, 1), effet = ('0x%08X'):format(effect) })
        return
    end

    if not data.isOnEntity then
        local sc = pedCoords(P.src)
        if sc and Utils.dist3(sc.x, sc.y, sc.z, data.posX or 0, data.posY or 0, data.posZ or 0) > c.remoteDistance then
            CancelEvent()
            Rempart.Detect(P.src, 'ptfx_blocked', { raison = 'particule lointaine' }, { score = 15 })
        end
    end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Feux
-- ─────────────────────────────────────────────────────────────────────────────

AddEventHandler('fireEvent', function(sender, data)
    local c = cfg.fire
    if not c.enabled or type(data) ~= 'table' or type(data.fires) ~= 'table' then return end
    local P = senderContext(sender, 'fire_spam')
    if not P then return end

    local now = Rempart.now()
    local w = window(P, 'fires', c.window)
    local n = 0
    for _ = 1, #data.fires do n = w:add(now, true) end
    if n > c.maxPerWindow then
        CancelEvent()
        if (n - #data.fires) <= c.maxPerWindow or n % 20 == 0 then
            Rempart.Detect(P.src, 'fire_spam', { nombre = n, fenetre = c.window .. ' s' })
        end
        return
    end

    local sc = pedCoords(P.src)
    for _, f in ipairs(data.fires) do
        if c.onPlayers and f.isEntity and (f.weaponHash or 0) == 0 then
            local target = isOtherPlayerPed(P.src, f.entityGlobalId)
            if target then
                CancelEvent()
                local victim = Rempart.Players.fromPed(target)
                Rempart.Detect(P.src, 'fire_player', { victime = victim and ('%s (#%d)'):format(victim.name, victim.src) or '?' })
                return
            end
        end
        if sc and not f.isEntity and Utils.dist3(sc.x, sc.y, sc.z, f.posX or 0, f.posY or 0, f.posZ or 0) > c.remoteDistance then
            CancelEvent()
            Rempart.Detect(P.src, 'fire_spam', { raison = 'feu lointain' }, { score = 15 })
            return
        end
    end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Projectiles
-- ─────────────────────────────────────────────────────────────────────────────

AddEventHandler('startProjectileEvent', function(sender, data)
    local c = cfg.projectiles
    if not c.enabled or type(data) ~= 'table' then return end
    local P = senderContext(sender, 'projectile_spawn')
    if not P then return end

    local n = window(P, 'projectiles', c.window):add(Rempart.now(), true)
    if n > c.maxPerWindow then
        CancelEvent()
        if n == c.maxPerWindow + 1 or n % 20 == 0 then
            Rempart.Detect(P.src, 'projectile_spam', { nombre = n, fenetre = c.window .. ' s' })
        end
        return
    end

    local weapon = Rempart.weaponName(data.weaponHash)

    -- projectile attribué au ped d'un autre joueur
    local framed = isOtherPlayerPed(P.src, data.ownerId)
    if framed then
        CancelEvent()
        local victim = Rempart.Players.fromPed(framed)
        Rempart.Detect(P.src, 'projectile_spawn', { raison = 'attribué à un autre joueur', arme = weapon,
            accuse = victim and ('%s (#%d)'):format(victim.name, victim.src) or '?' })
        return
    end

    -- projectile qui naît loin du tireur (magic bullet / pluie de roquettes)
    local sc, ped = pedCoords(P.src)
    if sc then
        local maxDist = c.maxSpawnDistance + ((GetVehiclePedIsIn(ped, false) ~= 0) and 40.0 or 0.0)
        local d = Utils.dist3(sc.x, sc.y, sc.z, data.initialPositionX or 0, data.initialPositionY or 0, data.initialPositionZ or 0)
        if d > maxDist then
            CancelEvent()
            Rempart.Detect(P.src, 'projectile_spawn', { raison = 'origine éloignée', distance = math.floor(d) .. ' m',
                arme = weapon, tir_scripte = data.commandFireSingleBullet == true })
            return
        end
    end
end)
