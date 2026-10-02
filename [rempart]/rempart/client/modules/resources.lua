--[[
    Client : intégrité de l'environnement.
      • ressources présentes localement mais inconnues du serveur (injection type Eulen)
      • ressource arrêtée localement (resource stopper) — en ignorant les arrêts massifs
        (déconnexion, fermeture du jeu) ; le serveur reconfirme 10 s plus tard
      • commandes enregistrées par une ressource inconnue / commandes de menus connus
      • dictionnaires de textures de menus connus, et textures DUI créées à l'exécution
        par les menus Lua (GetTextureResolution ≠ 4×4)
      • variables globales de menus Lua injectés dans CE module (les shields font de même
        dans vos ressources)
      • dimensions des modèles de personnage modifiées (hitbox agrandie)
]]

local M = RMP.module('resources', { interval = 10000 })

local RES = GetCurrentResourceName()
local reported = {}       -- ressource injectée déjà signalée
local reportedCmd = {}    -- commande déjà signalée
local stopTimes = {}      -- horodatages d'arrêts récents (détection des arrêts massifs)
local cheatCommands, cheatTextures, runtimeTextures, cheatGlobals = {}, {}, {}, {}
local nextCommands, nextTextures, nextGlobals, nextHitbox = 0, 0, 0, 0
local dims = {}           -- modèle -> dimensions de référence

local function isInternal(name)
    return name == nil or name == '' or name:find('^_+cfx') ~= nil
end

function M.init(cfg)
    for _, c in ipairs(cfg.cheatCommands or {}) do cheatCommands[c:lower()] = true end
    cheatTextures = cfg.cheatTextures or {}
    runtimeTextures = cfg.runtimeTextures or {}
    cheatGlobals = cfg.cheatGlobals or {}
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
    -- textures DUI créées à l'exécution : une texture absente mesure 4×4
    for _, t in ipairs(runtimeTextures) do
        local r = GetTextureResolution(t[1], t[2])
        if r and (r.x ~= 4.0 or r.y ~= 4.0) then
            RMP.detect('texture_menu', { dict = t[1], texture = t[2], menu = t[3] })
            return
        end
    end
end

local function scanGlobals()
    for _, name in ipairs(cheatGlobals) do
        if rawget(_G, name) ~= nil then
            RMP.detect('lua_menu', { variable = name, ressource = RES })
            return
        end
    end
end

-- Modèles multijoueur : leurs dimensions ne changent jamais en jeu. Un « hitbox expander »
-- les agrandit (souvent pour les AUTRES joueurs) : référence à l'initialisation + bornes
-- physiques absolues (un humain ne fait pas 2,5 m de large).
local FREEMODE = { 'mp_m_freemode_01', 'mp_f_freemode_01' }

local function dimsOf(model)
    local mn, mx = GetModelDimensions(model)
    if not mn or not mx then return nil end
    return { mn.x, mn.y, mn.z, mx.x, mx.y, mx.z }
end

local function implausible(d)
    return d[1] < -1.2 or d[4] > 1.2 or d[2] < -1.0 or d[5] > 1.0 or d[3] < -1.6 or d[6] > 1.4
end

local function scanHitbox()
    for _, name in ipairs(FREEMODE) do
        local model = GetHashKey(name)
        local d = dimsOf(model)
        if d then
            local ref = dims[model]
            if not ref then
                dims[model] = d
                if implausible(d) then
                    RMP.detect('client_hitbox', { modele = name, largeur = d[4] - d[1], hauteur = d[6] - d[3] })
                    return
                end
            else
                for i = 1, 6 do
                    if math.abs(d[i] - ref[i]) > 0.02 then
                        RMP.detect('client_hitbox', { modele = name, axe = i, avant = ref[i], apres = d[i] })
                        return
                    end
                end
            end
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
    if checks.globals ~= false and now >= nextGlobals then
        nextGlobals = now + 30000
        scanGlobals()
    end
    if checks.hitbox ~= false and now >= nextHitbox then
        nextHitbox = now + 30000
        scanHitbox()
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
