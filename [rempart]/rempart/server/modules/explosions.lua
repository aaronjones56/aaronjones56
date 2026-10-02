--[[
    Module : explosions (explosionEvent) — 100 % serveur, annulables.

    Note anti-faux-positif : quand un véhicule explose suite aux dégâts d'un joueur A,
    l'explosion est créée par le PROPRIÉTAIRE du véhicule (joueur B) mais créditée à A.
    Le contrôle « explosion attribuée à autrui » ne vise donc que les types d'armes
    (grenade, roquette, munitions explosives…), jamais les explosions de véhicules/objets.
]]

Rempart.module('explosions', {})
local cfg = Config.Explosions
local policy = Rempart.lookup.explosionPolicy

-- Types créés par l'arme du joueur lui-même : le "coupable" doit être son propre ped.
local WEAPON_TYPES = Utils.set({ 0, 1, 2, 3, 4, 5, 25, 36, 38, 40, 43, 45, 59, 61, 70, 72, 81, 83 })

local function typeName(t)
    local info = Lists.Explosions[t]
    return info and ('%s (%d)'):format(info[1], t) or tostring(t)
end

local function nearestOtherPlayer(sender, x, y, z, radius)
    local best, bestDist = nil, radius
    for src, P in Rempart.Players.each() do
        if src ~= sender then
            local ped = GetPlayerPed(src)
            if ped ~= 0 then
                local c = GetEntityCoords(ped)
                local d = Utils.dist3(c.x, c.y, c.z, x, y, z)
                if d <= bestDist then best, bestDist = P, d end
            end
        end
    end
    return best, bestDist
end

AddEventHandler('explosionEvent', function(sender, ev)
    if not cfg.enabled or type(ev) ~= 'table' then return end
    sender = tonumber(sender)
    local P = sender and Rempart.Players.get(sender)
    if not P then return end
    if Rempart.Perms.immune(P, Rempart.Detections.explosion_blocked) then return end

    local etype = tonumber(ev.explosionType) or -1
    local x, y, z = ev.posX or 0.0, ev.posY or 0.0, ev.posZ or 0.0
    local now = Rempart.now()

    -- 1. Spam
    local st = P.state
    st.explosions = st.explosions or Utils.Window(cfg.window * 1000)
    local count = st.explosions:add(now, etype)
    if count > cfg.maxPerWindow then
        CancelEvent()
        if count == cfg.maxPerWindow + 1 or count % 10 == 0 then
            Rempart.Detect(sender, 'explosion_spam', { nombre = count, fenetre = cfg.window .. ' s', type = typeName(etype) })
        end
        return
    end

    -- 2. Type interdit (un type inconnu — futur DLC — est seulement surveillé)
    local pol = policy[etype] or 'flag'
    if pol == 'block' then
        CancelEvent()
        Rempart.Detect(sender, 'explosion_blocked', { type = typeName(etype), position = ('%.0f, %.0f, %.0f'):format(x, y, z) })
        return
    end

    local senderPed = GetPlayerPed(sender)

    -- 3. Explosion d'arme attribuée au ped d'un autre joueur (blame)
    if WEAPON_TYPES[etype] and ev.ownerNetId and ev.ownerNetId ~= 0 then
        local culprit = NetworkGetEntityFromNetworkId(ev.ownerNetId)
        if culprit and culprit ~= 0 and DoesEntityExist(culprit) and GetEntityType(culprit) == 1
            and IsPedAPlayer(culprit) and culprit ~= senderPed then
            CancelEvent()
            local framed = Rempart.Players.fromPed(culprit)
            Rempart.Detect(sender, 'explosion_blame', {
                type = typeName(etype), accuse = framed and ('%s (#%d)'):format(framed.name, framed.src) or '?',
            })
            return
        end
    end

    -- 4. Explosion modifiée (invisible avec dégâts, inaudible, amplifiée, séisme)
    local damaging = (ev.damageScale or 1.0) > 0.0
    local reasons = {}
    if cfg.blockInvisible and ev.isInvisible and damaging then reasons[#reasons + 1] = 'invisible' end
    if cfg.blockSilent and ev.isAudible == false and damaging then reasons[#reasons + 1] = 'inaudible' end
    if (ev.damageScale or 0) > cfg.maxDamageScale then reasons[#reasons + 1] = ('dégâts ×%.1f'):format(ev.damageScale) end
    if (ev.cameraShake or 0) > cfg.maxCameraShake then reasons[#reasons + 1] = ('secousse %.1f'):format(ev.cameraShake) end
    if #reasons > 0 then
        CancelEvent()
        Rempart.Detect(sender, 'explosion_modified', { type = typeName(etype), anomalies = table.concat(reasons, ', ') })
        return
    end

    -- 5. Explosion « posée » sur un autre joueur, loin de l'auteur
    if senderPed ~= 0 and not Lists.ExplosionsVehicle[etype] then
        local c = GetEntityCoords(senderPed)
        local dist = Utils.dist3(c.x, c.y, c.z, x, y, z)
        if dist > cfg.remoteDistance then
            local victim, vdist = nearestOtherPlayer(sender, x, y, z, cfg.nearVictimDistance)
            if victim then
                CancelEvent()
                Rempart.Detect(sender, 'explosion_remote', {
                    type = typeName(etype), distance = math.floor(dist) .. ' m',
                    victime = ('%s (#%d) à %.1f m'):format(victim.name, victim.src, vdist),
                })
                return
            end
        end
    end

    -- 6. Types rares : score faible, l'explosion est autorisée
    if pol == 'flag' and count >= 4 then
        Rempart.Detect(sender, 'explosion_spam', { type = typeName(etype), nombre = count }, { score = 8 })
    end
end)
