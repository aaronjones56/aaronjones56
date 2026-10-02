--[[
    Client : témoin de tirs à travers les murs (magic bullet / wallbang).

    Le serveur n'a pas la géométrie de la carte ; la victime, si. Quand le joueur local
    est touché par un autre joueur, on trace des lignes de vue (tête/torse du tireur vers
    tête/torse/bassin de la victime) contre la géométrie de la carte, en ignorant le verre
    et les surfaces traversables (grillages). Si TOUTES sont bloquées, et le restent
    400 puis 800 ms plus tard (l'avantage du « peeker » se dissipe en quelques centaines
    de ms), la victime témoigne.

    Le témoignage seul ne vaut rien : le serveur ne le retient que s'il a lui-même vu ce
    tireur toucher ce témoin, et ne sanctionne que lorsque PLUSIEURS victimes distinctes
    accusent le même tireur. Un tricheur ne peut donc pas faire accuser un innocent.
]]

local M = RMP.module('witness', {})

local BONES_FROM = { 31086, 24818 }          -- SKEL_Head, SKEL_Spine3
local BONES_TO = { 31086, 24818, 11816 }     -- + SKEL_Pelvis
local MAP_ONLY = 1                            -- géométrie de la carte
local IGNORE_GLASS_SEETHROUGH_NOCOLLISION = 7
local MIN_DISTANCE = 15.0

local lastReport = {}    -- id serveur du tireur -> ms

local function isHit(v)
    return v == true or v == 1
end

--- Toutes les lignes de vue tireur -> victime sont-elles bloquées par la carte ?
local function blocked(attacker, victim)
    for _, bf in ipairs(BONES_FROM) do
        local a = GetPedBoneCoords(attacker, bf, 0.0, 0.0, 0.0)
        for _, bt in ipairs(BONES_TO) do
            local b = GetPedBoneCoords(victim, bt, 0.0, 0.0, 0.0)
            local h = StartExpensiveSynchronousShapeTestLosProbe(a.x, a.y, a.z, b.x, b.y, b.z, MAP_ONLY, attacker,
                IGNORE_GLASS_SEETHROUGH_NOCOLLISION)
            local _, hit = GetShapeTestResult(h)
            if not isHit(hit) then return false end
        end
    end
    return true
end

function M.init() end

AddEventHandler('gameEventTriggered', function(name, args)
    if name ~= 'CEventNetworkEntityDamage' or not RMP.ready or not RMP.cfg.witness then return end
    if (RMP.cfg.checks or {}).witness == false or type(args) ~= 'table' then return end
    local me = PlayerPedId()
    local victim, attacker = args[1], args[2]
    if victim ~= me or not attacker or attacker == 0 or attacker == me then return end
    if not DoesEntityExist(attacker) or not IsPedAPlayer(attacker) then return end
    if IsPedInAnyVehicle(attacker, false) or IsPedInAnyVehicle(me, false) then return end

    local idx = NetworkGetPlayerIndexFromPed(attacker)
    if not idx or idx == -1 then return end
    local sid = GetPlayerServerId(idx)
    local now = GetGameTimer()
    if lastReport[sid] and now - lastReport[sid] < 10000 then return end

    local a, v = GetEntityCoords(attacker), GetEntityCoords(me)
    local dist = #(a - v)
    if dist < MIN_DISTANCE or not blocked(attacker, me) then return end
    lastReport[sid] = now

    CreateThread(function()
        for _ = 1, 2 do
            Wait(400)
            if not DoesEntityExist(attacker) or not blocked(attacker, PlayerPedId()) then return end
        end
        RMP.send('wit', { a = sid, d = math.floor(dist) })
    end)
end)
