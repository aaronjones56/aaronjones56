--[[
    Module : combat (weaponDamageEvent) — 100 % serveur.

    weaponDamageEvent est émis quand un client veut infliger des dégâts à une entité
    qu'il ne possède pas (donc à tout autre joueur). Il est annulable : les dégâts
    physiquement impossibles sont bloqués AVANT d'atteindre la victime.

      • distance tireur→victime > portée max de la famille d'arme (×2-3 la réalité)
      • victime dans une autre dimension (routing bucket)
      • arme interdite
      • dégâts forcés démesurés (overrideDefaultDamage)
      • angle impossible : la cible est DERRIÈRE le tireur à pied (silent aim) —
        utilise le cap du ped synchronisé, pas la caméra (fiable côté serveur)
      • cadence de touches impossible (rapid fire)
      • nombreuses cibles distinctes en 2 s (kill aura / « kill all »)
]]

Rempart.module('combat', {})
local cfg = Config.Combat
local weaponInfo = Rempart.lookup.weaponInfo
local blacklist = Rempart.lookup.weaponBlacklist

local function victimEntity(data)
    local id = data.hitGlobalId
    if (not id or id == 0) and type(data.hitGlobalIds) == 'table' then id = data.hitGlobalIds[1] end
    if not id or id == 0 then return nil end
    local ent = NetworkGetEntityFromNetworkId(id)
    if not ent or ent == 0 or not DoesEntityExist(ent) then return nil end
    return ent
end

AddEventHandler('weaponDamageEvent', function(sender, data)
    if not cfg.enabled or type(data) ~= 'table' then return end
    sender = tonumber(sender)
    local P = sender and Rempart.Players.get(sender)
    if not P or P.punished then return end
    if Rempart.Perms.immune(P, Rempart.Detections.combat_distance) then return end

    local shooter = GetPlayerPed(sender)
    if shooter == 0 then return end
    local victim = victimEntity(data)
    if not victim then return end

    local weapon = Utils.h32(data.weaponType)
    local info = weaponInfo[weapon]
    local victimP = (GetEntityType(victim) == 1 and IsPedAPlayer(victim)) and Rempart.Players.fromPed(victim) or nil

    -- horodatage de combat (preuve exigée par la détection godmode)
    local nowMs = Rempart.now()
    P.state.lastCombat = nowMs
    if victimP then victimP.state.lastCombat = nowMs end
    local victimLabel = victimP and ('%s (#%d)'):format(victimP.name, victimP.src) or 'PNJ'
    local wname = Rempart.weaponName(weapon)

    -- 1. Arme interdite
    if blacklist[weapon] then
        if cfg.cancelImpossible then CancelEvent() end
        Rempart.Detect(sender, 'combat_blacklisted', { arme = wname, victime = victimLabel })
        return
    end

    -- 2. Dimensions différentes
    if victimP and GetPlayerRoutingBucket(sender) ~= GetPlayerRoutingBucket(victimP.src) then
        if cfg.cancelImpossible then CancelEvent() end
        Rempart.Detect(sender, 'combat_bucket', { arme = wname, victime = victimLabel })
        return
    end

    -- 3. Dégâts forcés démesurés sur un joueur
    if victimP and data.overrideDefaultDamage and (data.weaponDamage or 0) > cfg.maxOverrideDamage then
        if cfg.cancelImpossible then CancelEvent() end
        Rempart.Detect(sender, 'combat_override', { degats = data.weaponDamage, arme = wname, victime = victimLabel })
        return
    end

    if not info then return end -- arme inconnue (custom, véhicule, environnement) : pas d'heuristique

    local sc, vc = GetEntityCoords(shooter), GetEntityCoords(victim)
    local dist = Utils.dist3(sc.x, sc.y, sc.z, vc.x, vc.y, vc.z)

    -- 4. Distance impossible
    if dist > info.range then
        if cfg.cancelImpossible then CancelEvent() end
        Rempart.Detect(sender, 'combat_distance', {
            arme = wname, distance = math.floor(dist) .. ' m', max = math.floor(info.range) .. ' m', victime = victimLabel,
        })
        return
    end

    local now = Rempart.now()
    local st = P.state

    -- 5. Angle impossible (tireur à pied, arme visée, hors bout portant)
    if cfg.angleCheck and info.aim and dist >= cfg.angleMinDistance and GetVehiclePedIsIn(shooter, false) == 0
        and not IsPedRagdoll(shooter) then
        local heading = GetEntityHeading(shooter)
        local bearing = Utils.bearing(sc.x, sc.y, vc.x, vc.y)
        local diff = Utils.angleDiff(heading, bearing)
        if diff > cfg.maxAngle then
            Rempart.Detect(sender, 'combat_angle', {
                angle = math.floor(diff) .. '°', distance = math.floor(dist) .. ' m', arme = wname, victime = victimLabel,
            })
        end
    end

    -- 6. Cadence
    if cfg.rateCheck then
        st.hitRates = st.hitRates or {}
        local w = st.hitRates[weapon]
        if not w then
            w = Utils.Window(1000)
            st.hitRates[weapon] = w
        end
        local n = w:add(now, true)
        if n > info.rate and (not st.rateFlagged or now - st.rateFlagged > 1000) then
            st.rateFlagged = now
            Rempart.Detect(sender, 'combat_rate', { arme = wname, touches_par_s = n, max = info.rate })
        end
    end

    -- 7. Multi-cibles (kill aura) : joueurs distincts touchés avec une arme visée
    if victimP and info.aim then
        st.targets = st.targets or Utils.Window(2000)
        st.targets:add(now, victimP.src)
        local distinct = st.targets:distinct(now)
        if distinct >= cfg.multiTarget and (not st.auraFlagged or now - st.auraFlagged > 2000) then
            st.auraFlagged = now
            Rempart.Detect(sender, 'combat_multitarget', { joueurs = distinct, fenetre = '2 s', arme = wname })
        end
    end
end)
