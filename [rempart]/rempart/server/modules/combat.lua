--[[
    Module : combat (weaponDamageEvent) — 100 % serveur.

    weaponDamageEvent est émis quand un client veut infliger des dégâts à une entité
    qu'il ne possède pas (donc à tout autre joueur). Il est annulable : les dégâts
    physiquement impossibles sont bloqués AVANT d'atteindre la victime.

      • dégâts forgés : arme « environnementale » (chute, noyade, saignement…) envoyée
        à un autre joueur — le jeu ne le fait jamais, les menus si (« fold », kill all)
      • distance tireur→victime > portée max de la famille d'arme (×2-3 la réalité),
        dont la portée du taser
      • victime dans une autre dimension (routing bucket)
      • arme interdite
      • dégâts forcés démesurés (overrideDefaultDamage)
      • angle impossible : la cible est DERRIÈRE le tireur à pied (cap du ped)
      • caméra : la cible est hors du champ de la caméra synchronisée du tireur
        (GetPlayerCameraRotation) — silent aim / magic bullet
      • cadence de touches impossible (rapid fire)
      • nombreuses cibles distinctes en 2 s (kill aura / « kill all »)
      • victime qui encaisse plusieurs fois des dégâts mortels sans que sa santé baisse
        (godmode par immunités SetEntityProofs/CanBeDamaged, invisible pour GetPlayerInvincible)
      • victime d'un taser qui ne tombe jamais (anti-ragdoll)
      • tirs à travers les murs : les victimes (client) signalent les touches reçues sans
        ligne de vue ; le serveur ne les retient que s'il a bien vu le tir, et seulement
        quand plusieurs victimes distinctes accusent le même tireur
]]

Rempart.module('combat', {})
local cfg = Config.Combat
local lookup = Rempart.lookup
local weaponInfo = lookup.weaponInfo
local blacklist = lookup.weaponBlacklist

local function victimEntity(data)
    local id = data.hitGlobalId
    if (not id or id == 0) and type(data.hitGlobalIds) == 'table' then id = data.hitGlobalIds[1] end
    if not id or id == 0 then return nil end
    local ent = NetworkGetEntityFromNetworkId(id)
    if not ent or ent == 0 or not DoesEntityExist(ent) then return nil end
    return ent
end

local function label(V)
    return V and ('%s (#%d)'):format(V.name, V.src) or 'PNJ'
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Dégâts encaissés sans effet
-- ─────────────────────────────────────────────────────────────────────────────

local DEATH_HEALTH = 100   -- santé d'un ped joueur mort (≤ 100)

local function trackAbsorb(V, ped, damage)
    local st = V.state
    local now = Rempart.now()
    local a = st.absorb
    if not a or (now - a.start) > 3000 then
        a = { start = now, total = 0, hp = GetEntityHealth(ped), armour = GetPedArmour(ped) or 0, ped = ped }
        st.absorb = a
    end
    a.total = a.total + damage
    if a.checking then return end
    -- Plusieurs fois le budget létal : même un serveur qui réduit les dégâts des armes
    -- (×0,3) verrait la santé de la victime baisser.
    local budget = math.max(0, a.hp - DEATH_HEALTH) + a.armour
    if a.hp <= DEATH_HEALTH + 1 or a.total < budget * 2.5 + 50 then return end
    a.checking = true
    SetTimeout(1500, function()
        if st.absorb == a then st.absorb = nil end
        if V.punished or Rempart.Players.get(V.src) ~= V then return end
        if Rempart.Players.inGrace(V) or Rempart.Reports.declared(V, 'invincible')
            or Rempart.Reports.declared(V, 'heal', 12000) then
            return
        end
        local p2 = GetPlayerPed(V.src)
        if p2 ~= a.ped or not DoesEntityExist(p2) then return end
        local hp = GetEntityHealth(p2)
        local armour = GetPedArmour(p2) or 0
        -- ni la santé ni l'armure n'ont baissé malgré des tirs mortels répétés
        if hp > DEATH_HEALTH and hp >= a.hp - 5 and armour >= a.armour - 5 then
            st.absorbStrikes = (st.absorbStrikes or 0) + 1
            if st.absorbStrikes >= 2 then
                st.absorbStrikes = 0
                Rempart.Detect(V.src, 'godmode_absorb', {
                    degats_recus = math.floor(a.total), sante_avant = a.hp, sante_apres = hp, armure = armour,
                })
            end
        else
            st.absorbStrikes = 0
        end
    end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Taser sans chute (anti-ragdoll)
-- ─────────────────────────────────────────────────────────────────────────────

local function checkTazed(V, ped)
    local st = V.state
    local now = Rempart.now()
    if st.tazeCheck and now - st.tazeCheck < 5000 then return end
    st.tazeCheck = now
    CreateThread(function()
        for _ = 1, 8 do
            Wait(400)
            if Rempart.Players.get(V.src) ~= V or GetPlayerPed(V.src) ~= ped or not DoesEntityExist(ped) then return end
            if IsPedRagdoll(ped) then
                st.tazeStrikes = 0
                return
            end
        end
        if GetEntityHealth(ped) <= DEATH_HEALTH or GetVehiclePedIsIn(ped, false) ~= 0 or IsEntityPositionFrozen(ped) then
            return
        end
        if Rempart.Players.inGrace(V) or Rempart.Reports.declared(V, 'ragdoll') or Rempart.Reports.declared(V, 'invincible') then
            return
        end
        st.tazeStrikes = (st.tazeStrikes or 0) + 1
        if st.tazeStrikes >= 3 then
            st.tazeStrikes = 0
            Rempart.Detect(V.src, 'tazer_ragdoll', { tirs_sans_chute = 3 })
        end
    end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- weaponDamageEvent
-- ─────────────────────────────────────────────────────────────────────────────

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
    local damage = tonumber(data.weaponDamage) or 0

    -- horodatage de combat (preuve exigée par la détection godmode)
    local nowMs = Rempart.now()
    P.state.lastCombat = nowMs
    if victimP then victimP.state.lastCombat = nowMs end
    local victimLabel = label(victimP)
    local wname = Rempart.weaponName(weapon)

    -- 0. Dégâts forgés : arme environnementale visant un autre joueur
    if cfg.forgedDamage and victimP then
        local forged = lookup.forgedDamage[weapon]
        if forged or (weapon == lookup.birdCrap and damage > Lists.BirdCrap.maxDamage) then
            CancelEvent()
            Rempart.Detect(sender, 'combat_forged', {
                arme = forged or 'WEAPON_BIRD_CRAP', degats = damage, victime = victimLabel,
            })
            return
        end
    end

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
    if victimP and data.overrideDefaultDamage and damage > cfg.maxOverrideDamage then
        if cfg.cancelImpossible then CancelEvent() end
        Rempart.Detect(sender, 'combat_override', { degats = damage, arme = wname, victime = victimLabel })
        return
    end

    if not info then return end -- arme inconnue (custom, véhicule, environnement) : pas d'heuristique

    local sc, vc = GetEntityCoords(shooter), GetEntityCoords(victim)
    local dist = Utils.dist3(sc.x, sc.y, sc.z, vc.x, vc.y, vc.z)

    -- 4. Distance impossible (dont la portée du taser)
    if dist > info.range then
        if cfg.cancelImpossible then CancelEvent() end
        Rempart.Detect(sender, 'combat_distance', {
            arme = wname, distance = math.floor(dist) .. ' m', max = math.floor(info.range) .. ' m', victime = victimLabel,
        })
        return
    end

    local now = Rempart.now()
    local st = P.state
    local onFoot = GetVehiclePedIsIn(shooter, false) == 0

    -- 5. Angle impossible (tireur à pied, arme visée, hors bout portant)
    if cfg.angleCheck and info.aim and dist >= cfg.angleMinDistance and onFoot and not IsPedRagdoll(shooter) then
        local heading = GetEntityHeading(shooter)
        local bearing = Utils.bearing(sc.x, sc.y, vc.x, vc.y)
        local diff = Utils.angleDiff(heading, bearing)
        if diff > cfg.maxAngle then
            Rempart.Detect(sender, 'combat_angle', {
                angle = math.floor(diff) .. '°', distance = math.floor(dist) .. ' m', arme = wname, victime = victimLabel,
            })
        end
    end

    -- 6. Caméra : la victime doit être dans le champ de la caméra synchronisée du tireur.
    -- Le cap du ped peut diverger légitimement de la visée ; la caméra, non (sauf caméra libre).
    if cfg.cameraCheck and victimP and info.aim and onFoot and dist >= cfg.cameraMinDistance
        and not IsPlayerInFreeCamMode(sender) then
        local rot = GetPlayerCameraRotation(sender)
        if rot and (rot.x ~= 0.0 or rot.z ~= 0.0) then
            local camHeading = math.deg(rot.z) % 360.0
            local bearing = Utils.bearing(sc.x, sc.y, vc.x, vc.y)
            local diff = Utils.angleDiff(camHeading, bearing)
            if diff > cfg.cameraMaxAngle then
                Rempart.Detect(sender, 'combat_camera', {
                    ecart_camera = math.floor(diff) .. '°', distance = math.floor(dist) .. ' m', arme = wname,
                    victime = victimLabel,
                })
            end
        end
    end

    -- 7. Cadence
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

    -- 8. Multi-cibles (kill aura) : joueurs distincts touchés avec une arme visée
    if victimP and info.aim then
        st.targets = st.targets or Utils.Window(2000)
        st.targets:add(now, victimP.src)
        local distinct = st.targets:distinct(now)
        if distinct >= cfg.multiTarget and (not st.auraFlagged or now - st.auraFlagged > 2000) then
            st.auraFlagged = now
            Rempart.Detect(sender, 'combat_multitarget', { joueurs = distinct, fenetre = '2 s', arme = wname })
        end
    end

    if victimP then
        -- trace du tir côté victime (recoupement des témoignages « sans ligne de vue »)
        local vs = victimP.state
        vs.hitBy = vs.hitBy or {}
        vs.hitBy[sender] = now

        -- 9. Taser : la victime doit tomber
        if info.group == 'stungun' then
            if cfg.tazerRagdoll then checkTazed(victimP, victim) end
        -- 10. Dégâts mortels encaissés sans effet
        elseif cfg.absorbCheck and info.group ~= 'melee' and damage > 0 then
            trackAbsorb(victimP, victim, damage)
        end
    end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Témoignages des victimes : touché sans ligne de vue (tir à travers les murs)
-- ─────────────────────────────────────────────────────────────────────────────

Rempart.Channel.on('wit', function(V, payload)
    local w = cfg.wallbang
    if not w or not w.enabled or type(payload) ~= 'table' then return end
    local attackerSrc = math.tointeger(tonumber(payload.a))
    local A = attackerSrc and Rempart.Players.get(attackerSrc)
    if not A or A == V or A.punished then return end
    -- le serveur doit avoir vu ce tireur toucher ce témoin il y a moins de 5 s
    local hit = V.state.hitBy and V.state.hitBy[attackerSrc]
    local now = Rempart.now()
    if not hit or (now - hit) > 5000 then return end
    V.state.hitBy[attackerSrc] = nil   -- un témoignage par tir vu

    local st = A.state
    st.wallbang = st.wallbang or {}
    local key = V.ids.license or ('#' .. V.src)
    st.wallbang[key] = now
    local reporters, limit = 0, now - (w.window or 1800) * 1000
    for k, t in pairs(st.wallbang) do
        if t < limit then st.wallbang[k] = nil else reporters = reporters + 1 end
    end
    if reporters >= (w.minReporters or 2) then
        Rempart.Detect(A.src, 'combat_wallbang', {
            victimes = reporters, dernier_temoin = label(V),
            distance = tonumber(payload.d) and (math.floor(payload.d) .. ' m') or '?',
        })
    end
end)
