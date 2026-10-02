--[[
    Client : intégrité de l'environnement.
      • ressources présentes localement mais inconnues du serveur (injection type Eulen)
      • ressource arrêtée localement (resource stopper) — en ignorant les arrêts massifs
        (déconnexion, fermeture du jeu) ; le serveur reconfirme 10 s plus tard
      • commandes enregistrées par une ressource inconnue / commandes de menus connus
      • dictionnaires de textures de menus connus
]]

local M = RMP.module('resources', { interval = 10000 })

local RES = GetCurrentResourceName()
local reported = {}       -- ressource injectée déjà signalée
local reportedCmd = {}    -- commande déjà signalée
local stopTimes = {}      -- horodatages d'arrêts récents (détection des arrêts massifs)
local cheatCommands, cheatTextures = {}, {}
local nextCommands, nextTextures = 0, 0

local function isInternal(name)
    return name == nil or name == '' or name:find('^_+cfx') ~= nil
end

function M.init(cfg)
    for _, c in ipairs(cfg.cheatCommands or {}) do cheatCommands[c:lower()] = true end
    cheatTextures = cfg.cheatTextures or {}
end

local function scanResources()
    local unknown = {}
    for _, name in ipairs(RMP.listResources()) do
        if not RMP.serverResources[name] and not reported[name] and not isInternal(name) then
            reported[name] = true
            unknown[#unknown + 1] = name
        end
    end
    if #unknown > 0 then RMP.send('res', unknown) end
end

local function scanCommands()
    for _, cmd in ipairs(GetRegisteredCommands() or {}) do
        local name, res = cmd.name, cmd.resource
        if type(name) == 'string' then
            local id = name .. '@' .. tostring(res)
            if not reportedCmd[id] and not isInternal(res) then
                if not RMP.serverResources[res] or cheatCommands[name:lower()] then
                    reportedCmd[id] = true
                    RMP.detect('command_injected', { name = name, resource = res })
                end
            end
        end
    end
end

local function scanTextures()
    for _, dict in ipairs(cheatTextures) do
        if HasStreamedTextureDictLoaded(dict) then
            RMP.detect('texture_menu', { dict = dict })
            return
        end
    end
end

function M.tick(now)
    local checks = RMP.cfg.checks or {}
    if checks.resources ~= false then scanResources() end
    if checks.commands ~= false and now >= nextCommands then
        nextCommands = now + 30000
        scanCommands()
    end
    if checks.textures ~= false and now >= nextTextures then
        nextTextures = now + 20000
        scanTextures()
    end
end

-- Arrêt local d'une ressource
AddEventHandler('onClientResourceStop', function(name)
    if name == RES or not RMP.ready then return end
    local now = GetGameTimer()
    stopTimes[#stopTimes + 1] = now
    SetTimeout(2000, function()
        -- arrêt massif (déconnexion / fermeture) : on ignore
        local recent = 0
        for _, t in ipairs(stopTimes) do
            if now - t < 4000 and t - now < 4000 then recent = recent + 1 end
        end
        if recent >= 3 then return end
        if not NetworkIsPlayerActive(PlayerId()) then return end
        if (RMP.cfg.checks or {}).resources == false then return end
        RMP.send('stop', { name = name })
    end)
    if #stopTimes > 50 then stopTimes = { now } end
end)

-- Démarrage local d'une ressource inconnue : on laisse au serveur le temps de diffuser sa liste
AddEventHandler('onClientResourceStart', function(name)
    if not RMP.ready or name == RES then return end
    SetTimeout(4000, function()
        if not RMP.serverResources[name] and not reported[name] and not isInternal(name) then
            reported[name] = true
            RMP.send('res', { name })
        end
    end)
end)
