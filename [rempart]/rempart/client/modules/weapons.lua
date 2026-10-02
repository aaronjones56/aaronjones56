--[[
    Client : armes interdites en main et modificateurs de dégâts locaux.
    (Le serveur contrôle aussi l'arme sélectionnée et les modificateurs synchronisés.)
]]

local M = RMP.module('weapons', { interval = 1500 })

local blacklist = {}
local TOL = 0.02

function M.init(cfg)
    for _, h in ipairs(cfg.weaponBlacklist or {}) do blacklist[h & 0xFFFFFFFF] = true end
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

    local pid = PlayerId()
    local maxDmg = (RMP.cfg.maxDamageModifier or 1.0) + TOL
    local maxMelee = (RMP.cfg.maxMeleeModifier or 1.0) + TOL
    local dmg = GetPlayerWeaponDamageModifier(pid)
    local melee = GetPlayerMeleeWeaponDamageModifier(pid)
    if (dmg and dmg > maxDmg) or (melee and melee > maxMelee) then
        RMP.detect('client_weapon', { modificateur_armes = dmg, modificateur_melee = melee })
    end
end
