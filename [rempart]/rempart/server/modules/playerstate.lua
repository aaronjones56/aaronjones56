--[[
    Module : état du joueur — 100 % serveur.

    Ces valeurs sont lues dans les nœuds de synchronisation OneSync du joueur
    (CPlayerGameStateDataNode…) : un menu qui les modifie via les natives du jeu les
    réplique vers le serveur (seul un cheat qui falsifie la synchro elle-même y échappe,
    d'où les contrôles complémentaires côté client et le score cumulatif).
      • GetPlayerInvincible           (SetPlayerInvincible)
      • IsPlayerUsingSuperJump        (SetSuperJumpThisFrame)
      • GetPlayerWeaponDamageModifier / Melee / Defense (multiplicateurs de dégâts)
      • GetPlayerMaxHealth / MaxArmour, santé et armure courantes
      • IsEntityVisible en mouvement, modèle de ped, caméra libre éloignée
      • GetAirDragMultiplierForPlayersVehicle (boost de vitesse véhicule)
    Les modificateurs sont quantifiés au transport (8 à 10 bits) : tolérance ±0.02.
]]

Rempart.module('playerstate', {})
local cfg = Config.PlayerState
local declared = function(P, k) return Rempart.Reports.declared(P, k) end

local TOL = 0.02

local function strike(P, key, cond, needed)
    local st = P.state
    st.strikes = st.strikes or {}
    if cond then
        st.strikes[key] = (st.strikes[key] or 0) + 1
        if st.strikes[key] >= (needed or 2) then
            st.strikes[key] = 0
            return true
        end
    else
        st.strikes[key] = 0
    end
    return false
end

local function check(src, P)
    if Rempart.Players.inGrace(P) then return end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return end
    local health = GetEntityHealth(ped)
    local alive = health > 0
    local speed = Rempart.Movement.speed(P)

    -- Godmode (drapeau joueur synchronisé). Exige une preuve de combat (a tiré ou a été touché
    -- dans les 5 s) : zones sûres et scripts de mort rendent légitimement invincible hors combat.
    if cfg.godmode and alive then
        local inCombat = (Rempart.now() - (P.state.lastCombat or 0)) < 5000
        local god = GetPlayerInvincible(src) and inCombat and not declared(P, 'invincible')
        if strike(P, 'god', god, 2) then
            Rempart.Detect(src, 'godmode', { source = 'GetPlayerInvincible', sante = health, vitesse = Utils.round(speed, 1) })
        end
    end

    -- Super saut
    if cfg.superJump then
        if strike(P, 'jump', IsPlayerUsingSuperJump(src) and not declared(P, 'superjump'), 1) then
            Rempart.Detect(src, 'superjump', {})
        end
    end

    -- Modificateurs de dégâts / défense
    local dmg = GetPlayerWeaponDamageModifier(src)
    if dmg and dmg > cfg.maxWeaponDamageModifier + TOL then
        Rempart.Detect(src, 'damage_modifier', { type = 'armes', valeur = Utils.round(dmg, 2), max = cfg.maxWeaponDamageModifier })
    end
    local melee = GetPlayerMeleeWeaponDamageModifier(src)
    if melee and melee > cfg.maxMeleeDamageModifier + TOL then
        Rempart.Detect(src, 'damage_modifier', { type = 'mêlée', valeur = Utils.round(melee, 2), max = cfg.maxMeleeDamageModifier })
    end
    local def = GetPlayerWeaponDefenseModifier(src)
    if def and def ~= 0.0 and (def < cfg.minWeaponDefenseModifier - TOL or def > cfg.maxWeaponDefenseModifier + TOL) then
        Rempart.Detect(src, 'defense_modifier', { valeur = Utils.round(def, 2) })
    end

    -- Santé / armure
    local maxHealth = GetPlayerMaxHealth(src)
    local maxArmour = GetPlayerMaxArmour(src)
    local armour = GetPedArmour(ped)
    local anomalies = {}
    if maxHealth and maxHealth > cfg.maxHealth then anomalies[#anomalies + 1] = ('santé max %d'):format(maxHealth) end
    if maxArmour and maxArmour > cfg.maxArmour then anomalies[#anomalies + 1] = ('armure max %d'):format(maxArmour) end
    if health > cfg.maxHealth + 1 then anomalies[#anomalies + 1] = ('santé %d'):format(health) end
    if armour and armour > cfg.maxArmour + 1 then anomalies[#anomalies + 1] = ('armure %d'):format(armour) end
    if strike(P, 'hp', #anomalies > 0, 2) then
        Rempart.Detect(src, 'health_overflow', { anomalies = table.concat(anomalies, ', ') })
    end

    local veh = GetVehiclePedIsIn(ped, false)
    local moving = Rempart.Movement.speed(P) > 1.5

    -- Invisible en mouvement, à pied
    if cfg.invisible and veh == 0 then
        if strike(P, 'invis', moving and not IsEntityVisible(ped) and not declared(P, 'invisible'), 2) then
            Rempart.Detect(src, 'invisible', { vitesse = Utils.round(Rempart.Movement.speed(P), 1) .. ' m/s' })
        end
    end

    -- Modèle de ped interdit
    local model = Utils.h32(GetEntityModel(ped))
    if Rempart.lookup.pedBlacklist[model] then
        Rempart.Detect(src, 'ped_blacklisted', { modele = Rempart.lookup.pedBlacklist[model] })
    end

    -- Caméra libre éloignée du personnage
    if cfg.freecamDistance and cfg.freecamDistance > 0 and IsPlayerInFreeCamMode(src) then
        local focus = GetPlayerFocusPos(src)
        local c = GetEntityCoords(ped)
        local d = focus and Utils.dist3(focus.x, focus.y, focus.z, c.x, c.y, c.z) or 0
        if strike(P, 'cam', d > cfg.freecamDistance and not declared(P, 'camera') and not declared(P, 'spectate'), 3) then
            Rempart.Detect(src, 'freecam', { distance = math.floor(d) .. ' m' })
        end
    else
        strike(P, 'cam', false)
    end

    -- Boost de traînée aérodynamique (vitesse véhicule)
    if cfg.airDrag then
        local drag = GetAirDragMultiplierForPlayersVehicle(src)
        if drag and drag > 1.0 + 0.05 then
            Rempart.Detect(src, 'air_drag', { valeur = Utils.round(drag, 2) })
        end
    end
end

CreateThread(function()
    while true do
        Wait(cfg.interval)
        if cfg.enabled then
            for src, P in Rempart.Players.each() do
                if not P.punished then
                    local ok, err = pcall(check, src, P)
                    if not ok then Rempart.Log.debug('état #%d : %s', src, tostring(err)) end
                end
            end
        end
    end
end)
