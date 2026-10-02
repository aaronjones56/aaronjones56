--[[
    Client : véhicule conduit par le joueur.
      • véhicule indestructible (GetEntityCanBeDamaged) non déclaré
      • couple moteur boosté (GetVehicleCheatPowerIncrease) non déclaré
      • vitesse au-delà de la vitesse max estimée du modèle (mods inclus) × facteur
    Les aéronefs et bateaux sont exclus du contrôle de vitesse.
]]

local M = RMP.module('vehicles', { interval = 1000 })

local strikes = { god = 0, speed = 0 }
local LAND_EXCLUDED = { [14] = true, [15] = true, [16] = true, [21] = true } -- bateaux, hélicos, avions, trains

function M.tick()
    local checks = RMP.cfg.checks or {}
    if checks.vehicles == false or RMP.inGrace() then return end
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 or GetPedInVehicleSeat(veh, -1) ~= ped then
        strikes.god, strikes.speed = 0, 0
        return
    end

    -- Véhicule indestructible
    if not GetEntityCanBeDamaged(veh) and not RMP.declared('vehiclegod') then
        strikes.god = strikes.god + 1
        if strikes.god >= 5 then
            strikes.god = 0
            RMP.detect('client_vehicle', { anomalie = 'véhicule indestructible' })
        end
    else
        strikes.god = 0
    end

    -- Couple moteur boosté (les scripts « nitro » restent sous ×2 ; les menus utilisent ×10 à ×50)
    local power = GetVehicleCheatPowerIncrease(veh)
    if power and power > 2.5 and not RMP.declared('vehiclepower') then
        strikes.power = (strikes.power or 0) + 1
        if strikes.power >= 3 then
            strikes.power = 0
            RMP.detect('client_vehicle', { anomalie = 'couple moteur', valeur = math.floor(power * 100) / 100 })
        end
    else
        strikes.power = 0
    end

    -- Vitesse anormale (véhicules terrestres au sol)
    local class = GetVehicleClass(veh)
    if not LAND_EXCLUDED[class] and not IsEntityInAir(veh) and not RMP.declared('vehiclepower') then
        local speed = GetEntitySpeed(veh)
        local maxSpeed = GetVehicleEstimatedMaxSpeed(veh)
        local limit = maxSpeed * (RMP.cfg.vehicleSpeedFactor or 1.6) + 15.0
        if maxSpeed > 1.0 and speed > limit then
            strikes.speed = strikes.speed + 1
            if strikes.speed >= 3 then
                strikes.speed = 0
                RMP.detect('client_vehicle', { anomalie = 'vitesse', vitesse = math.floor(speed), max = math.floor(maxSpeed) })
            end
        else
            strikes.speed = 0
        end
    end
end
