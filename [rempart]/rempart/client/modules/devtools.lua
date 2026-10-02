--[[
    Client : DevTools NUI.
    Les DevTools permettent d'appeler directement les callbacks NUI de vos ressources
    (inventaires, banques…) avec des données forgées. La page html/index.html exécute un
    piège `debugger` : il ne fait rien… sauf si les DevTools sont ouverts (le script
    se met en pause). Deux déclenchements consécutifs sont exigés côté page.
]]

local M = RMP.module('devtools', {})
local reported = false

RegisterNUICallback('dt', function(_, cb)
    cb('ok')
    if reported or not RMP.ready then return end
    if (RMP.cfg.checks or {}).devtools == false then return end
    reported = true
    RMP.detect('nui_devtools', {})
end)

function M.init() end
