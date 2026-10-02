--[[
    Module : armes — 100 % serveur.
      • giveWeaponEvent / removeWeaponEvent / removeAllWeaponsEvent : ces événements
        ne sont émis QUE lorsqu'un client agit sur un ped qu'il ne possède pas.
        Viser le ped d'un autre joueur = menu de triche (« give all weapons »,
        « remove weapons all »…). Les PNJ restent autorisés.
      • Arme interdite en main : lecture serveur de l'arme sélectionnée (synchro OneSync).
]]

local M = Rempart.module('weapons', {})
local cfg = Config.Weapons
local blacklist = Rempart.lookup.weaponBlacklist
local weaponInfo = Rempart.lookup.weaponInfo

local function weaponName(hash)
    local h = Utils.h32(hash)
    local info = weaponInfo[h]
    return (info and info.name) or blacklist[h] or ('0x%08X'):format(h)
end

--- Retourne (P cible) si le ped réseau visé est celui d'un AUTRE joueur.
local function otherPlayerTarget(sender, netId)
    if not netId or netId == 0 then return nil end
    local ent = NetworkGetEntityFromNetworkId(netId)
    if not ent or ent == 0 or not DoesEntityExist(ent) then return nil end
    if GetEntityType(ent) ~= 1 or not IsPedAPlayer(ent) then return nil end
    if ent == GetPlayerPed(sender) then return nil end
    return Rempart.Players.fromPed(ent) or { name = '?', src = -1 }
end

local function guard(sender, detectionId)
    if not cfg.enabled then return nil end
    sender = tonumber(sender)
    local P = sender and Rempart.Players.get(sender)
    if not P or Rempart.Perms.immune(P, Rempart.Detections[detectionId]) then return nil end
    return P
end

AddEventHandler('giveWeaponEvent', function(sender, data)
    if not cfg.blockGiveToPlayers or type(data) ~= 'table' then return end
    local P = guard(sender, 'weapon_give_player')
    if not P then return end
    local target = otherPlayerTarget(P.src, data.pedId)
    if not target then return end
    CancelEvent()
    Rempart.Detect(P.src, 'weapon_give_player', {
        victime = ('%s (#%d)'):format(target.name, target.src), arme = weaponName(data.weaponType),
        munitions = data.ammo,
    })
end)

AddEventHandler('removeWeaponEvent', function(sender, data)
    if not cfg.blockRemoveFromPlayers or type(data) ~= 'table' then return end
    local P = guard(sender, 'weapon_remove_player')
    if not P then return end
    local target = otherPlayerTarget(P.src, data.pedId)
    if not target then return end
    CancelEvent()
    Rempart.Detect(P.src, 'weapon_remove_player', {
        victime = ('%s (#%d)'):format(target.name, target.src), arme = weaponName(data.weaponType),
    })
end)

AddEventHandler('removeAllWeaponsEvent', function(sender, data)
    if not cfg.blockRemoveFromPlayers or type(data) ~= 'table' then return end
    local P = guard(sender, 'weapon_remove_player')
    if not P then return end
    local target = otherPlayerTarget(P.src, data.pedId)
    if not target then return end
    CancelEvent()
    Rempart.Detect(P.src, 'weapon_remove_player', {
        victime = ('%s (#%d)'):format(target.name, target.src), arme = 'toutes',
    })
end)

M.weaponName = weaponName
Rempart.weaponName = weaponName

-- Arme interdite en main (contrôle périodique serveur)
CreateThread(function()
    while true do
        Wait(math.max(500, cfg.checkInterval))
        if cfg.enabled and next(blacklist) then
            for src, P in Rempart.Players.each() do
                if not P.punished then
                    local ped = GetPlayerPed(src)
                    if ped ~= 0 then
                        local w = Utils.h32(GetSelectedPedWeapon(ped))
                        if blacklist[w] then
                            local action = Rempart.Detect(src, 'weapon_blacklisted', { arme = weaponName(w) })
                            if cfg.removeBlacklisted and action ~= 'immune' then
                                RemoveWeaponFromPed(ped, w)
                            end
                        end
                    end
                end
            end
        end
    end
end)
