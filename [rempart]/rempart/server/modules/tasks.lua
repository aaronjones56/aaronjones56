--[[
    Module : tâches forcées — 100 % serveur, annulables.
      • clearPedTasksEvent : ClearPedTasksImmediately sur le ped d'un AUTRE joueur
        (éjection de véhicule, gel, annulation d'animation à distance).
      • givePedScriptedTaskEvent : tâche scriptée imposée à un autre joueur.
    Les PNJ possédés par d'autres clients restent autorisés (braquages, escortes…).
]]

Rempart.module('tasks', {})
local cfg = Config.Tasks

local function check(sender, netId, detectionId, extra)
    sender = tonumber(sender)
    local P = sender and Rempart.Players.get(sender)
    if not P or P.punished or Rempart.Perms.immune(P, Rempart.Detections[detectionId]) then return end
    if not netId or netId == 0 then return end
    local ent = NetworkGetEntityFromNetworkId(netId)
    if not ent or ent == 0 or not DoesEntityExist(ent) then return end
    if GetEntityType(ent) ~= 1 or not IsPedAPlayer(ent) or ent == GetPlayerPed(sender) then return end
    CancelEvent()
    local victim = Rempart.Players.fromPed(ent)
    local details = { victime = victim and ('%s (#%d)'):format(victim.name, victim.src) or '?' }
    for k, v in pairs(extra or {}) do details[k] = v end
    Rempart.Detect(sender, detectionId, details)
end

AddEventHandler('clearPedTasksEvent', function(sender, data)
    if not cfg.enabled or not cfg.blockClearOnPlayers or type(data) ~= 'table' then return end
    check(sender, data.pedId, 'task_clear_player', { immediat = data.immediately == true })
end)

AddEventHandler('givePedScriptedTaskEvent', function(sender, data)
    if not cfg.enabled or not cfg.blockScriptedOnPlayers or type(data) ~= 'table' then return end
    check(sender, data.entityNetId, 'task_force_player', { tache = data.taskId })
end)
