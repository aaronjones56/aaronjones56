--[[
    Client : état du personnage.
      godmode · spectateur · invisibilité · noclip/vol · caméra libre · visions · ped miniature · anti-ragdoll

    Garde-fous anti-faux-positif :
      • déclarations des scripts légitimes (shield) : invisible, invincible, caméra…
      • périodes de grâce (apparition, réanimation, téléportation déclarée)
      • « preuve de comportement » : un joueur à terre invincible (script de mort)
        est immobile ; un tricheur en godmode se déplace ou tire
      • plusieurs échantillons consécutifs requis
]]

local M = RMP.module('player', { interval = 1000 })

local GetPlayerInvincible2 = GetPlayerInvincible_2 or GetPlayerInvincible2
local strikes = {}
local last = { ped = 0, pos = nil, health = 0, shotAt = 0, hitAt = 0 }

-- Le joueur a-t-il été touché ? (preuve de combat pour le godmode)
AddEventHandler('gameEventTriggered', function(name, args)
    if name == 'CEventNetworkEntityDamage' and type(args) == 'table' and args[1] == PlayerPedId() then
        last.hitAt = GetGameTimer()
    end
end)

local function strike(key, cond, needed)
    if cond then
        strikes[key] = (strikes[key] or 0) + 1
        if strikes[key] >= needed then
            strikes[key] = 0
            return true
        end
    else
        strikes[key] = 0
    end
    return false
end

local function godmodeSignals(ped)
    local signals = {}
    local pid = PlayerId()
    if GetPlayerInvincible(pid) or (GetPlayerInvincible2 and GetPlayerInvincible2(pid)) then
        signals[#signals + 1] = 'joueur invincible'
    end
    if not GetEntityCanBeDamaged(ped) then signals[#signals + 1] = 'entité indestructible' end
    local _, bullet, fire, explosion, collision, melee = GetEntityProofs(ped)
    if bullet and fire and explosion and melee then signals[#signals + 1] = 'toutes protections' end
    if collision and bullet then signals[#signals + 1] = 'protection collision' end
    return signals
end

local function busyState(ped)
    return IsPedFalling(ped) or IsPedInParachuteFreeFall(ped) or GetPedParachuteState(ped) > 0
        or IsPedRagdoll(ped) or IsPedClimbing(ped) or IsPedSwimming(ped) or IsPedJumping(ped)
        or IsEntityAttached(ped) or IsPedInAnyVehicle(ped, true) or IsPedGettingIntoAVehicle(ped)
end

function M.tick(now)
    local checks = RMP.cfg.checks or {}
    local cfg = RMP.cfg
    local ped = PlayerPedId()
    if ped == 0 or not DoesEntityExist(ped) then return end

    local pos = GetEntityCoords(ped)
    local health = GetEntityHealth(ped)

    -- nouveau ped ou réanimation => grâce
    if ped ~= last.ped then
        RMP.grace(10)
    elseif last.health <= 101 and health > last.health + 50 then
        RMP.grace(10)
    end
    if IsPedShooting(ped) then last.shotAt = now end

    local moved = last.pos and #(pos - last.pos) or 0.0
    last.ped, last.pos, last.health = ped, pos, health

    if RMP.inGrace() or IsEntityDead(ped) or IsPedDeadOrDying(ped, true) then return end
    if IsPlayerSwitchInProgress() or IsScreenFadedOut() or GetIsLoadingScreenActive() then return end

    -- preuve de combat : a tiré ou a été touché récemment (exclut zones sûres et scripts de mort)
    local inCombat = (now - last.shotAt) < 5000 or (now - last.hitAt) < 5000 or IsPedInMeleeCombat(ped)
    local onFoot = not IsPedInAnyVehicle(ped, true)

    -- Godmode
    if checks.godmode ~= false and not RMP.declared('invincible') then
        local signals = godmodeSignals(ped)
        if strike('god', #signals > 0 and inCombat, 3) then
            RMP.detect('client_godmode', { indices = table.concat(signals, ', '), touche = (now - last.hitAt) < 5000 })
        end
    end

    -- Mode spectateur
    if checks.spectate ~= false then
        if strike('spec', NetworkIsInSpectatorMode() and not RMP.declared('spectate'), 2) then
            RMP.detect('client_spectate', {})
        end
    end

    -- Invisible en mouvement
    if checks.invisible ~= false and onFoot then
        if strike('invis', not IsEntityVisible(ped) and moved > 1.5 and not RMP.declared('invisible'), 2) then
            RMP.detect('client_invisible', { deplacement = math.floor(moved) })
        end
    end

    -- Noclip / vol : déplacement sans vitesse physique, ou en l'air sans chute
    if checks.noclip ~= false and onFoot and not busyState(ped) and not RMP.declared('tp', 5000) then
        local speed = GetEntitySpeed(ped)
        local height = GetEntityHeightAboveGround(ped)
        local vel = GetEntityVelocity(ped)
        local ghostMove = moved > 3.0 and speed < 0.5                       -- coordonnées forcées image par image
        local flying = height > (cfg.noclipHeight or 8.0) and math.abs(vel.z) < 0.6 and moved > 2.0
        local noCollision = GetEntityCollisionDisabled(ped) and moved > 2.0 and not RMP.declared('collision')
        if strike('noclip', ghostMove or flying or noCollision, 3) then
            RMP.detect('client_noclip', {
                deplacement = math.floor(moved), vitesse = math.floor(speed), hauteur = math.floor(height),
                fantome = ghostMove, vol = flying, sans_collision = noCollision,
            })
        end
    end

    -- Caméra libre éloignée du personnage
    if checks.freecam ~= false and not RMP.declared('camera') and not RMP.declared('spectate') then
        local cam = GetFinalRenderedCamCoord()
        local dist = #(cam - pos)
        local cutscene = IsCutsceneActive() or IsCutscenePlaying()
        if strike('cam', dist > (cfg.freecamDistance or 120.0) and not cutscene, 5) then
            RMP.detect('client_freecam', { distance = math.floor(dist), camera_scriptee = GetRenderingCam() ~= -1 })
        end
    end

    -- Visions spéciales
    if checks.vision then
        if strike('vision', (GetUsingseethrough() or GetUsingnightvision()) and not RMP.declared('vision'), 3) then
            RMP.detect('client_vision', { thermique = GetUsingseethrough(), nocturne = GetUsingnightvision() })
        end
    end

    -- Ped miniature (hitbox réduite)
    if checks.tinyPed ~= false then
        if strike('tiny', GetPedConfigFlag(ped, 223, true), 2) then
            RMP.detect('client_tiny_ped', {})
        end
    end

    -- Anti-ragdoll
    if checks.ragdoll then
        if strike('ragdoll', not CanPedRagdoll(ped) and not RMP.declared('ragdoll'), 5) then
            RMP.detect('client_ragdoll', {})
        end
    end
end
