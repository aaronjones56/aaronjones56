--[[
    Rempart — séquence de démarrage du serveur.
]]

local function banner()
    print('^5')
    print('   ██████╗ ███████╗███╗   ███╗██████╗  █████╗ ██████╗ ████████╗')
    print('   ██╔══██╗██╔════╝████╗ ████║██╔══██╗██╔══██╗██╔══██╗╚══██╔══╝')
    print('   ██████╔╝█████╗  ██╔████╔██║██████╔╝███████║██████╔╝   ██║')
    print('   ██╔══██╗██╔══╝  ██║╚██╔╝██║██╔═══╝ ██╔══██║██╔══██╗   ██║')
    print('   ██║  ██║███████╗██║ ╚═╝ ██║██║     ██║  ██║██║  ██║   ██║')
    print('   ╚═╝  ╚═╝╚══════╝╚═╝     ╚═╝╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝^7')
    print(('   ^7Anti-cheat serveur-autoritaire v%s — ressource « %s »^7'):format(Rempart.version, Rempart.res))
    print('')
end

CreateThread(function()
    banner()

    if GetConvar('onesync', 'off') == 'off' then
        Rempart.Log.error('OneSync est DÉSACTIVÉ : la plupart des protections serveur sont inopérantes. Ajoutez « set onesync on ».')
    end

    -- Stockage puis bans
    local storageReady = promise.new()
    Rempart.Storage.init(function() storageReady:resolve(true) end)
    Citizen.Await(storageReady)

    local bansReady = promise.new()
    Rempart.Bans.load(function(count, expired)
        Rempart.Log.ok('%d ban(s) chargé(s) depuis %s%s.', count, Rempart.Storage.backend,
            expired > 0 and (' (%d expiré(s) purgé(s))'):format(expired) or '')
        bansReady:resolve(true)
    end)
    Citizen.Await(bansReady)

    -- Joueurs déjà connectés (redémarrage à chaud de la ressource)
    for _, id in ipairs(GetPlayers()) do
        local P = Rempart.Players.ensure(tonumber(id))
        if P then Rempart.Players.grace(P, 60) end
    end

    -- Modules
    for _, mod in ipairs(Rempart.modules) do
        if mod.init then
            local ok, err = pcall(mod.init)
            if not ok then Rempart.Log.error('Module %s : échec d\'initialisation : %s', mod.name, tostring(err)) end
        end
    end

    Rempart.ready = true
    Rempart.Log.ok('Prêt : %d modules, %d détections, mode audit %s.', #Rempart.modules, Utils.count(Rempart.Detections),
        Config.AuditMode and '^3ACTIVÉ (aucune sanction)^2' or 'désactivé')
    for _, w in ipairs(Rempart.configWarnings) do Rempart.Log.warn(w) end
    Rempart.Log.file('start', { version = Rempart.version, res = Rempart.res, audit = Config.AuditMode })
end)
