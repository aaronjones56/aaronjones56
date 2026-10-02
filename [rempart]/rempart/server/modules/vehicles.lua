--[[
    Module : véhicules — 100 % serveur.
      • Santé moteur/carrosserie au-delà du maximum (véhicule « god »).
      • Réparations client non déclarées : FXServer incrémente un compteur
        (GetVehicleTotalRepairs) à chaque SetVehicleFixed côté client. Une réparation
        faite par un script légitime est déclarée par le shield ; sinon elle est signalée
        (score très faible par défaut : beaucoup de serveurs ont des scripts de réparation
        sans shield).
]]

Rempart.module('vehicles', {})
local cfg = Config.Vehicles

local repairs = {}  -- netId véhicule -> dernier compteur (0..15, rebouclage)

local function check(src, P)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return end
    local veh = GetVehiclePedIsIn(ped, false)
    if not veh or veh == 0 or GetPedInVehicleSeat(veh, -1) ~= ped then return end

    local engine, body = GetVehicleEngineHealth(veh), GetVehicleBodyHealth(veh)
    if (engine and engine > cfg.maxEngineHealth + 1.0) or (body and body > cfg.maxBodyHealth + 1.0) then
        Rempart.Detect(src, 'vehicle_health', { moteur = math.floor(engine or 0), carrosserie = math.floor(body or 0) })
    end

    if cfg.repairCheck then
        local netId = NetworkGetNetworkIdFromEntity(veh)
        local count = GetVehicleTotalRepairs(veh)
        local prev = repairs[netId]
        repairs[netId] = count
        if prev and count ~= prev then
            local delta = (count - prev) % 16
            if delta > 0 and not Rempart.Reports.declared(P, 'repair', 15000) then
                Rempart.Detect(src, 'vehicle_repair', { reparations = delta })
            end
        end
    end
end

CreateThread(function()
    while true do
        Wait(cfg.interval)
        if cfg.enabled then
            for src, P in Rempart.Players.each() do
                if not P.punished and not Rempart.Players.inGrace(P) then
                    local ok, err = pcall(check, src, P)
                    if not ok then Rempart.Log.debug('véhicules #%d : %s', src, tostring(err)) end
                end
            end
        end
    end
end)

AddEventHandler('entityRemoved', function(entity)
    if GetEntityType(entity) == 2 then
        repairs[NetworkGetNetworkIdFromEntity(entity)] = nil
    end
end)
