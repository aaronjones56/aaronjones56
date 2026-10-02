-- Scénarios serveur : démarrage, pipeline de détection, sanctions, bans, connexion.
local T = dofile('tests/lib/t.lua')
local F = dofile('tests/mocks/fivem.lua')

local function boot(opts)
    local env = F.new(opts)
    env:loadManifest('[rempart]/rempart', 'server')
    local G = env.G
    -- réglages de test : pas de captures, pas de délai de grâce, Discord inactif
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

local function dropped(env, src)
    for _, d in ipairs(env.dropped) do if d.src == src then return d.reason end end
    return nil
end

T.case('démarrage complet de la ressource', function()
    local env, G = boot()
    T.ok(G.Rempart.ready, 'Rempart.ready')
    T.ok(#G.Rempart.modules >= 12, 'modules chargés : ' .. #G.Rempart.modules)
    T.ok(G.Rempart.Detections.event_honeypot, 'catalogue')
    T.eq(env.convars['rempart:resource'], 'rempart', 'convar répliquée pour les shields')
    T.ok(env.commands.rmp, 'commande rmp enregistrée')
end)

T.case('score cumulatif, amortissement des répétitions et décroissance', function()
    local env, G = boot()
    G.Config.Client.enabled = false -- pas de module client simulé dans ce scénario
    local P = join(env, 1)
    G.Rempart.Detect(1, 'teleport', { test = 1 })            -- 15
    T.near(G.Rempart.Punish.currentScore(P), 15, 0.01)
    G.Rempart.Detect(1, 'teleport', { test = 2 })            -- répétition : 7.5
    T.near(G.Rempart.Punish.currentScore(P), 22.5, 0.01)
    env:advance(600000)                                       -- une demi-vie (10 min)
    T.near(G.Rempart.Punish.currentScore(P), 11.25, 0.05)
    T.eq(dropped(env, 1), nil, 'pas de sanction sous les seuils')
end)

T.case('seuil de kick puis de ban', function()
    local env, G = boot()
    join(env, 2)
    G.Rempart.Detect(2, 'combat_rate', {})        -- 35
    G.Rempart.Detect(2, 'noclip', {})             -- +40 = 75 -> kick
    env:advance(100)
    local reason = dropped(env, 2)
    T.ok(reason and reason:find('Expulsé'), 'kick attendu, obtenu : ' .. tostring(reason))

    join(env, 3)
    G.Rempart.Detect(3, 'damage_modifier', { valeur = 5 })  -- 100 -> ban
    env:advance(100)
    reason = dropped(env, 3)
    T.ok(reason and reason:find('banni'), 'ban attendu, obtenu : ' .. tostring(reason))
    T.eq(G.Rempart.Bans.count(), 1)
end)

T.case('mode audit : aucune sanction appliquée', function()
    local env, G = boot()
    G.Config.AuditMode = true
    join(env, 4)
    local action = G.Rempart.Detect(4, 'heartbeat_tamper', {})
    env:advance(100)
    T.eq(action, 'audit')
    T.eq(dropped(env, 4), nil)
    T.eq(G.Rempart.Bans.count(), 0)
end)

T.case('immunités : ACE bypass, ACE ciblée, txAdmin, exemption temporaire', function()
    local env, G = boot()
    join(env, 5, { ace = { ['rempart.bypass'] = true } })
    T.eq(G.Rempart.Detect(5, 'heartbeat_tamper', {}), 'immune')

    join(env, 6, { ace = { ['rempart.bypass.teleport'] = true } })
    T.eq(G.Rempart.Detect(6, 'teleport', {}), 'immune', 'bypass par détection')
    T.eq(G.Rempart.Detect(6, 'noclip', {}), 'warn', 'autres détections actives (40 pts : alerte staff)')

    join(env, 7, { ace = { ['rempart.bypass.movement'] = true } })
    T.eq(G.Rempart.Detect(7, 'speedhack', {}), 'immune', 'bypass par catégorie')

    join(env, 8)
    env:trigger('txAdmin:events:adminAuth', '', { netid = 8, isAdmin = true })
    T.eq(G.Rempart.Detect(8, 'noclip', {}), 'immune', 'admin txAdmin')

    local P9 = join(env, 9)
    G.Rempart.Perms.exempt(P9, 'state', 5)
    T.eq(G.Rempart.Detect(9, 'godmode', {}), 'immune', 'exemption de catégorie')
    env:advance(6000)
    T.ok(G.Rempart.Detect(9, 'godmode', {}) ~= 'immune', 'exemption expirée')
end)

T.case('ban : connexion refusée, contournement par tokens matériels', function()
    local env, G = boot()
    join(env, 10, { ids = { 'license:aaa', 'discord:111' }, tokens = { '2:hwid-1', '3:hwid-2' } })
    G.Rempart.Detect(10, 'resource_injected', { ressources = 'eulen' })
    env:advance(100)
    T.ok(dropped(env, 10), 'banni')
    local ban = G.Rempart.Bans.match({ 'license:aaa' }, {})
    T.ok(ban, 'ban indexé par licence')

    -- nouveau compte, même PC
    env.players[11] = { name = 'Nouveau', ids = { 'license:bbb', 'discord:222' }, tokens = { '2:hwid-1' } }
    local done
    local deferrals = {
        defer = function() end, update = function() end,
        done = function(msg) done = msg or false end,
    }
    env:trigger('playerConnecting', 'internal:11', 'Nouveau', function() end, deferrals)
    env:advance(100)
    T.ok(type(done) == 'string' and done:find(ban.id, 1, true), 'connexion refusée avec l\'id du ban')
    T.ok(G.Rempart.Bans.match({ 'license:bbb' }, {}), 'ban étendu à la nouvelle licence')
    T.eq(ban.evasions, 1)
end)

T.case('ban : persistance KVP et rechargement', function()
    local env, G = boot()
    local ban = G.Rempart.Bans.add({ name = 'X', reason = 'test', identifiers = { 'license:persist' }, tokens = {}, duration = 0 })
    T.ok(env.kvp['rmp:ban:' .. ban.id], 'écrit en KVP')
    G.Rempart.Bans.load()
    env:advance(10)
    T.ok(G.Rempart.Bans.get(ban.id), 'rechargé')
    -- ban temporaire expiré purgé au chargement
    local tmp = G.Rempart.Bans.add({ name = 'Y', reason = 'tmp', identifiers = { 'license:tmp' }, duration = 60 })
    tmp.expiresAt = os.time() - 1
    env.kvp['rmp:ban:' .. tmp.id] = env.G.json.encode(tmp)
    G.Rempart.Bans.load()
    env:advance(10)
    T.eq(G.Rempart.Bans.get(tmp.id), nil, 'ban expiré purgé')
end)

T.case('connexion : pseudos invalides', function()
    local env, G = boot()
    local check = G.Rempart.modulesByName.connection.checkName
    T.ok(check('Jean Dupont'))
    T.ok(not check('<img src=x onerror=alert(1)>'), 'HTML')
    T.ok(not check('a'), 'trop court')
    T.ok(not check(string.rep('x', 40)), 'trop long')
    T.ok(not check('Bob\226\128\139'), 'caractère invisible U+200B')
    T.ok(not check('^1^2^3'), 'uniquement des codes couleur')
    T.ok(check('Élodie Ünïcødé'), 'accents autorisés')
end)

T.case('commande rmp ban hors ligne + unban', function()
    local env, G = boot()
    env.commands.rmp(0, { 'ban', 'license:offline', '7d', 'triche', 'avérée' })
    local ban = G.Rempart.Bans.match({ 'license:offline' }, {})
    T.ok(ban, 'ban hors ligne créé')
    T.eq(ban.reason, 'triche avérée')
    T.ok(ban.expiresAt > os.time() + 6 * 86400)
    env.commands.rmp(0, { 'unban', ban.id })
    T.eq(G.Rempart.Bans.get(ban.id), nil)
end)

return T.finish()
