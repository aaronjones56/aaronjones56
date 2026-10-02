--[[
    Module : mouvement — 100 % serveur (positions synchronisées OneSync).

      • Téléportation : saut de position impossible en 1 échantillon.
        Exemptions : déclaration du shield (script légitime), API AllowTeleport,
        période de grâce (connexion, réapparition, changement de ped/dimension),
        et APPRENTISSAGE des points de téléportation légitimes : une destination
        utilisée par plusieurs joueurs distincts (ascenseur, intérieur, garage…)
        est automatiquement validée.
      • Vitesse à pied impossible (soutenue sur plusieurs échantillons).
      • Noclip : joueur à pied qui se déplace collisions coupées ou position gelée.
]]

local M = Rempart.module('movement', {})
Rempart.Movement = M
local cfg = Config.Movement

local points = {}          -- points de téléportation appris { x, y, z, players = { [license] = true }, n }
local pointsDirty = false
local expected = {}        -- src -> { untilMs, x, y, z } (téléportations autorisées par le serveur)

-- ─────────────────────────────────────────────────────────────────────────────
-- API : téléportation autorisée par un script serveur
-- ─────────────────────────────────────────────────────────────────────────────

function M.expect(src, coords, ms)
    expected[src] = {
        untilMs = Rempart.now() + (ms or 10000),
        x = coords and coords.x, y = coords and coords.y, z = coords and coords.z,
    }
end

local function isExpected(src, x, y, z)
    local e = expected[src]
    if not e then return false end
    if e.untilMs < Rempart.now() then
        expected[src] = nil
        return false
    end
    if not e.x then return true end
    return Utils.dist3(e.x, e.y, e.z, x, y, z) < 40.0
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Apprentissage des points de téléportation légitimes
-- ─────────────────────────────────────────────────────────────────────────────

local function findPoint(x, y, z)
    local r = cfg.teleport.learnRadius
    for _, p in ipairs(points) do
        if math.abs(p.x - x) <= r and math.abs(p.y - y) <= r and math.abs(p.z - z) <= r * 2 then
            return p
        end
    end
    return nil
end

local function learn(P, x, y, z)
    if not cfg.teleport.learnPoints then return false end
    local lic = P.ids.license or ('src' .. P.src)
    local p = findPoint(x, y, z)
    if not p then
        if #points >= 2000 then table.remove(points, 1) end
        p = { x = x, y = y, z = z, players = {}, n = 0 }
        points[#points + 1] = p
    end
    if not p.players[lic] then
        p.players[lic] = true
        p.n = p.n + 1
        pointsDirty = true
    end
    return p.n >= cfg.teleport.learnPlayers
end

function M.points() return points end

-- ─────────────────────────────────────────────────────────────────────────────
-- Échantillonnage
-- ─────────────────────────────────────────────────────────────────────────────

local AIR = { heli = true, plane = true }

local function resetState(P, ped, c, bucket, health)
    P.state.mv = {
        ped = ped, x = c.x, y = c.y, z = c.z, t = Rempart.now(), bucket = bucket, health = health,
        fast = 0, noclip = 0,
    }
end

local function sample(src, P)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 or not DoesEntityExist(ped) then
        P.state.mv = nil
        return
    end
    local c = GetEntityCoords(ped)
    local bucket = GetPlayerRoutingBucket(src)
    local health = GetEntityHealth(ped)
    local s = P.state.mv

    -- changement de ped (modèle/réapparition) ou de dimension : on repart de zéro avec grâce
    if not s or s.ped ~= ped or s.bucket ~= bucket then
        if s then Rempart.Players.grace(P, 8) end
        return resetState(P, ped, c, bucket, health)
    end

    local now = Rempart.now()
    local dt = (now - s.t) / 1000.0
    if dt <= 0.2 then return end
    if dt > 5.0 then return resetState(P, ped, c, bucket, health) end

    -- réanimation (santé qui remonte depuis l'état mort) : grâce
    if s.health <= 101 and health > s.health + 50 then
        Rempart.Players.grace(P, 10)
    end

    local dh = Utils.dist2(s.x, s.y, c.x, c.y)
    local dz = c.z - s.z
    local veh = GetVehiclePedIsIn(ped, false)
    local inGrace = Rempart.Players.inGrace(P)

    -- 1. Téléportation
    if cfg.teleport.enabled and not inGrace then
        local maxStep
        if veh == 0 then
            maxStep = cfg.teleport.footDistance
        elseif AIR[GetVehicleType(veh) or ''] then
            maxStep = cfg.teleport.airDistance
        else
            maxStep = cfg.teleport.vehicleDistance
        end
        maxStep = maxStep * math.max(1.0, dt)
        local jump = dh > maxStep or (veh == 0 and dz > 40.0)
        if jump then
            local legit = isExpected(src, c.x, c.y, c.z)
                or Rempart.Reports.teleportDeclared(P, c.x, c.y, c.z, 30.0, 12000)
            if not legit then
                local known = learn(P, c.x, c.y, c.z)
                if not known then
                    Rempart.Detect(src, 'teleport', {
                        distance = math.floor(Utils.dist3(s.x, s.y, s.z, c.x, c.y, c.z)) .. ' m',
                        depuis = ('%.0f, %.0f, %.0f'):format(s.x, s.y, s.z),
                        vers = ('%.0f, %.0f, %.0f'):format(c.x, c.y, c.z),
                        vehicule = veh ~= 0,
                    })
                end
            end
            return resetState(P, ped, c, bucket, health)
        end
    end

    local speed = dh / dt

    -- 2. Vitesse à pied
    if cfg.speed.enabled and veh == 0 and not inGrace then
        if speed > cfg.speed.footSpeed and math.abs(dz) < 3.0 * dt and not IsPedRagdoll(ped) then
            s.fast = s.fast + 1
            if s.fast >= cfg.speed.samples then
                Rempart.Detect(src, 'speedhack', { vitesse = Utils.round(speed, 1) .. ' m/s', max = cfg.speed.footSpeed .. ' m/s' })
                s.fast = 0
            end
        else
            s.fast = 0
        end
    end

    -- 3. Noclip (à pied, en mouvement)
    if cfg.noclip.enabled and veh == 0 and not inGrace and speed > cfg.noclip.minSpeed then
        local reasons = {}
        if GetEntityCollisionDisabled(ped) and not Rempart.Reports.declared(P, 'collision') then
            reasons[#reasons + 1] = 'collisions coupées'
        end
        if IsEntityPositionFrozen(ped) and not Rempart.Reports.declared(P, 'frozen') then
            reasons[#reasons + 1] = 'position gelée'
        end
        if #reasons > 0 then
            s.noclip = s.noclip + 1
            if s.noclip >= 2 then
                Rempart.Detect(src, 'noclip', { indices = table.concat(reasons, ', '), vitesse = Utils.round(speed, 1) .. ' m/s' })
                s.noclip = 0
            end
        else
            s.noclip = 0
        end
    end

    s.x, s.y, s.z, s.t, s.health = c.x, c.y, c.z, now, health
    s.speed = speed
end

-- Vitesse horizontale récente (utilisée par d'autres modules).
function M.speed(P)
    return (P.state.mv and P.state.mv.speed) or 0.0
end

AddEventHandler('respawnPlayerPedEvent', function(player)
    local P = Rempart.Players.get(tonumber(player))
    if P then Rempart.Players.grace(P, 10) end
end)

AddEventHandler('onPlayerBucketChange', function(player)
    local P = Rempart.Players.get(tonumber(player))
    if P then Rempart.Players.grace(P, 8) end
end)

function M.init()
    points = Rempart.Storage.get('tp_points', {})
    for _, p in ipairs(points) do
        p.players = p.players or {}
        p.n = Utils.count(p.players)
    end
end

CreateThread(function()
    while true do
        Wait(cfg.interval)
        if cfg.enabled then
            for src, P in Rempart.Players.each() do
                if not P.punished then
                    local ok, err = pcall(sample, src, P)
                    if not ok then Rempart.Log.debug('mouvement #%d : %s', src, tostring(err)) end
                end
            end
        end
    end
end)

CreateThread(function()
    while true do
        Wait(300000)
        if pointsDirty then
            pointsDirty = false
            Rempart.Storage.set('tp_points', points)
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res == Rempart.res and pointsDirty then Rempart.Storage.set('tp_points', points) end
end)

AddEventHandler('playerDropped', function()
    expected[tonumber(source) or -1] = nil
end)
