--[[
    Client : armes interdites en main, modificateurs de dégâts locaux et munitions
    modifiées (type de dégâts explosif/incendiaire sur une arme à balles : « explosive
    ammo » des menus). Le serveur contrôle aussi l'arme sélectionnée et les modificateurs.
]]

local M = RMP.module('weapons', { interval = 1500 })

local blacklist = {}
local specialAmmo = {}
local bulletGroups = {}
local TOL = 0.02
local DAMAGE_EXPLOSIVE, DAMAGE_FIRE = 5, 6
-- exceptions : armes à balles dont le type de dégâts est légitimement spécial
local EXEMPT = { 'WEAPON_FLAREGUN', 'WEAPON_RAYPISTOL', 'WEAPON_RAYCARBINE', 'WEAPON_MARKSMANPISTOL' }

function M.init(cfg)
    for _, h in ipairs(cfg.weaponBlacklist or {}) do blacklist[h & 0xFFFFFFFF] = true end
    for _, h in ipairs(cfg.specialAmmo or {}) do specialAmmo[h & 0xFFFFFFFF] = true end
    for _, n in ipairs(EXEMPT) do specialAmmo[GetHashKey(n) & 0xFFFFFFFF] = true end
    for _, g in ipairs({ 'GROUP_PISTOL', 'GROUP_SMG', 'GROUP_RIFLE', 'GROUP_MG', 'GROUP_SHOTGUN', 'GROUP_SNIPER' }) do
        bulletGroups[GetHashKey(g) & 0xFFFFFFFF] = true
    end
end

local function checkAmmo(weapon)
    if specialAmmo[weapon] then return end
    if not bulletGroups[GetWeapontypeGroup(weapon) & 0xFFFFFFFF] then return end
    local kind = GetWeaponDamageType(weapon)
    if kind == DAMAGE_EXPLOSIVE or kind == DAMAGE_FIRE then
        RMP.detect('client_ammo', { arme = ('0x%08X'):format(weapon), type_degats = kind })
    end
end

function M.tick()
    local checks = RMP.cfg.checks or {}
    if checks.weapons == false or RMP.inGrace() then return end
    local ped = PlayerPedId()
    if ped == 0 then return end

    local weapon = GetSelectedPedWeapon(ped) & 0xFFFFFFFF
    if blacklist[weapon] then
        RemoveWeaponFromPed(ped, weapon)
        RMP.detect('client_weapon', { arme = ('0x%08X'):format(weapon) })
        return
    end

    if checks.ammo ~= false and weapon ~= 0 then checkAmmo(weapon) end

    local pid = PlayerId()
    local maxDmg = (RMP.cfg.maxDamageModifier or 1.0) + TOL
    local maxMelee = (RMP.cfg.maxMeleeModifier or 1.0) + TOL
    local dmg = GetPlayerWeaponDamageModifier(pid)
    local melee = GetPlayerMeleeWeaponDamageModifier(pid)
    if (dmg and dmg > maxDmg) or (melee and melee > maxMelee) then
        RMP.detect('client_weapon', { modificateur_armes = dmg, modificateur_melee = melee })
    end
end
