-- Scénarios : shield inclus dans une ressource protégée (pare-feu bloquant + intentions serveur),
-- avec la politique réellement produite par l'anti-cheat.
local T = dofile('tests/lib/t.lua')
local F = dofile('tests/mocks/fivem.lua')

local SHIELD = '[rempart]/rempart/shield.lua'
local vector3 = F.new().G.vector3   -- vecteurs du simulateur (comme dans un vrai config.lua)

--- Démarre l'anti-cheat et capture la politique qu'il envoie à un shield qui s'annonce.
local function acWithPolicy(rules)
    local env = F.new()
    env:loadManifest('[rempart]/rempart', 'server')
    local G = env.G
    G.Config.Punish.screenshot = false
    G.Config.Punish.dropDelay = 0
    G.Config.Client.enabled = false
    G.Config.Events.firewall.rules = rules or {}
    env:advance(15000)
    local policy
    G.AddEventHandler('rempart:shield:policy', function(p) policy = p end)
    env:trigger('rempart:shield:hello', '', 'myjob')
    return env, policy
end

--- Ressource « myjob » protégée par le shield.
local function protected(policy)
    local env = F.new({ resource = 'myjob' })
    local G = env.G
    -- natives serveur détournées par le shield (absentes du simulateur de base)
    G.SetEntityCoords = function(h, x, y, z) env.entities[h].pos = G.vector3(x, y, z) end
    G.SetPlayerInvincible = function(player, toggle) env.players[tonumber(player)].invincible = toggle end
    env:load(SHIELD)

    env.calls, env.violations, env.intents = {}, {}, {}
    G.AddEventHandler('rempart:shield:violation', function(src, res, name, kind, info)
        env.violations[#env.violations + 1] = { src = src, res = res, name = name, kind = kind, info = info }
    end)
    G.AddEventHandler('rempart:shield:intent', function(kind, src, data)
        env.intents[#env.intents + 1] = { kind = kind, src = src, data = data }
    end)

    -- le « vrai » code de la ressource, écrit normalement
    for _, name in ipairs({ 'myjob:pay', 'myjob:admin', 'myjob:cuff', 'myjob:bank', 'myjob:save' }) do
        G.RegisterNetEvent(name, function(...)
            env.calls[#env.calls + 1] = { name = name, src = G.source, n = select('#', ...) }
        end)
    end
    G.RegisterServerEvent('myjob:legacy')
    G.AddEventHandler('myjob:legacy', function() env.calls[#env.calls + 1] = { name = 'myjob:legacy' } end)

    if policy then env:trigger('rempart:shield:policy', '', policy) end
    return env
end

local function count(env, name)
    local n = 0
    for _, c in ipairs(env.calls) do if c.name == name then n = n + 1 end end
    return n
end

local function violation(env, name, kind)
    for _, v in ipairs(env.violations) do
        if v.name == name and v.kind == kind then return v end
    end
    return nil
end

-- ─────────────────────────────────────────────────────────────────────────────

T.case('shield : passif tant que l\'anti-cheat n\'a envoyé aucune politique', function()
    local env = protected(nil)
    env:addPlayer(1)
    for _ = 1, 200 do env:trigger('myjob:pay', 1, 100) end
    T.eq(count(env, 'myjob:pay'), 200, 'aucun blocage sans politique')
    T.eq(#env.violations, 0)
end)

T.case('shield : politique de l\'anti-cheat (format réel) et limite de débit par règle', function()
    local _, policy = acWithPolicy({ ['myjob:pay'] = { rate = 1, per = 60 } })
    T.ok(policy and policy.rules['myjob:pay'] and policy.limits.maxString, 'politique reçue')
    local env = protected(policy)
    env:addPlayer(2)
    env:trigger('myjob:pay', 2, 100)
    env:trigger('myjob:pay', 2, 100)
    env:trigger('myjob:pay', 2, 100)
    T.eq(count(env, 'myjob:pay'), 1, '1 paiement par minute')
    T.ok(violation(env, 'myjob:pay', 'rate'), 'violation remontée')
    env:advance(61000)
    env:trigger('myjob:pay', 2, 100)
    T.eq(count(env, 'myjob:pay'), 2, 'jeton rechargé après 60 s')
end)

T.case('shield : débit par défaut et ressource héritée (RegisterServerEvent + AddEventHandler)', function()
    local _, policy = acWithPolicy()
    local env = protected(policy)
    env:addPlayer(3)
    for _ = 1, 100 do env:trigger('myjob:legacy', 3) end
    T.eq(count(env, 'myjob:legacy'), policy.burst, 'rafale par défaut respectée')
    T.ok(violation(env, 'myjob:legacy', 'rate'))
end)

T.case('shield : arguments malformés bloqués, arguments normaux acceptés', function()
    local _, policy = acWithPolicy()
    local env = protected(policy)
    env:addPlayer(4)
    local deep = {}
    local cur = deep
    for _ = 1, 20 do cur.x = {} cur = cur.x end
    local wide = {}
    for i = 1, 9000 do wide[i] = i end
    env:trigger('myjob:save', 4, 0 / 0)
    env:trigger('myjob:save', 4, math.huge)
    env:trigger('myjob:save', 4, string.rep('A', 70000))
    env:trigger('myjob:save', 4, deep)
    env:trigger('myjob:save', 4, wide)
    env:trigger('myjob:save', 4, 1e15)
    T.eq(count(env, 'myjob:save'), 0, 'aucune charge malformée ne passe')
    T.ok(violation(env, 'myjob:save', 'malformed'))
    env:trigger('myjob:save', 4, { items = { { name = 'bread', count = 2 } }, label = 'Inventaire' }, 42.5)
    T.eq(count(env, 'myjob:save'), 1, 'charge normale acceptée')
end)

T.case('shield : règles serverOnly, ACE et distance', function()
    local _, policy = acWithPolicy({
        ['myjob:admin'] = { serverOnly = true },
        ['myjob:cuff'] = { ace = 'job.police' },
        ['myjob:bank'] = { near = { vector3(150.0, -1040.0, 29.0) }, radius = 30.0 },
    })
    local env = protected(policy)
    env:addPlayer(5, { pos = env.G.vector3(0, 0, 70) })
    env:addPlayer(6, { ace = { ['job.police'] = true }, pos = env.G.vector3(155.0, -1035.0, 29.0) })

    env:trigger('myjob:admin', 5)
    T.eq(count(env, 'myjob:admin'), 0, 'serverOnly bloqué depuis un client')
    T.ok(violation(env, 'myjob:admin', 'serverOnly'))
    env:trigger('myjob:admin', '')
    T.eq(count(env, 'myjob:admin'), 1, 'serverOnly autorisé depuis le serveur')

    env:trigger('myjob:cuff', 5)
    env:trigger('myjob:cuff', 6)
    T.eq(count(env, 'myjob:cuff'), 1, 'seul le principal ACE passe')
    T.ok(violation(env, 'myjob:cuff', 'ace'))

    env:trigger('myjob:bank', 5)
    env:trigger('myjob:bank', 6)
    T.eq(count(env, 'myjob:bank'), 1, 'seul le joueur proche du guichet passe')
    T.ok(violation(env, 'myjob:bank', 'distance'))
end)

T.case('shield : quarantaine d\'un joueur sanctionné, levée à la déconnexion', function()
    local _, policy = acWithPolicy()
    local env = protected(policy)
    env:addPlayer(7)
    env:addPlayer(8)
    env:trigger('rempart:shield:quarantine', '', 7, true)
    env:trigger('myjob:save', 7, 1)
    env:trigger('myjob:save', 8, 1)
    T.eq(count(env, 'myjob:save'), 1, 'seul le joueur sain passe')
    env:trigger('rempart:shield:drop', '', 7)
    env:trigger('myjob:save', 7, 1)
    T.eq(count(env, 'myjob:save'), 2, 'nouvelle session : plus de quarantaine')
end)

T.case('shield : un client ne peut ni changer la politique ni lever une quarantaine', function()
    local _, policy = acWithPolicy({ ['myjob:pay'] = { rate = 1, per = 60 } })
    local env = protected(policy)
    env:addPlayer(9)
    -- une ressource tierce maladroite expose ces événements au réseau
    env.netSafe['rempart:shield:policy'] = true
    env.netSafe['rempart:shield:quarantine'] = true
    env:trigger('rempart:shield:quarantine', '', 9, true)
    env:trigger('rempart:shield:policy', 9, { rules = {} })
    env:trigger('rempart:shield:quarantine', 9, 9, false)
    env:trigger('myjob:pay', 9, 1)
    T.eq(count(env, 'myjob:pay'), 0, 'politique et quarantaine intactes')
end)

T.case('shield : intentions des scripts serveur (téléportation, invincibilité)', function()
    local env = protected(nil)
    env:addPlayer(10)
    local G = env.G
    local prop = env:spawnEntity({ type = 3, model = 1, owner = 10 })
    G.SetEntityCoords(prop, 1.0, 2.0, 3.0)
    T.eq(#env.intents, 0, 'objet : pas d\'intention')
    G.SetEntityCoords(env:ped(10), 100.0, 200.0, 30.0)
    T.eq(env.intents[1] and env.intents[1].kind, 'teleport')
    T.eq(env.intents[1].src, 10)
    T.eq(env:entity(env:ped(10)).pos.x, 100.0, 'native d\'origine appelée')
    G.SetPlayerInvincible(10, true)
    T.eq(env.intents[2] and env.intents[2].kind, 'invincible')
    T.eq(env.players[10].invincible, true)
end)

T.case('intégration : violation du shield => détection côté anti-cheat', function()
    local ac = acWithPolicy({ ['myjob:admin'] = { serverOnly = true } })
    local G = ac.G
    ac:addPlayer(11)
    ac:trigger('playerJoining', 'internal:11', '0')
    ac:trigger('rempart:shield:violation', '', 11, 'myjob', 'myjob:admin', 'serverOnly', {})
    local P = G.Rempart.Players.get(11)
    local h = P.hist:list()
    T.eq(h[#h] and h[#h].id, 'event_firewall')
    T.near(G.Rempart.Punish.currentScore(P), 60, 0.01)
    -- un client ne peut pas forger une violation au nom d'un autre joueur
    ac.netSafe['rempart:shield:violation'] = true
    ac:addPlayer(12)
    ac:trigger('playerJoining', 'internal:12', '0')
    ac:trigger('rempart:shield:violation', 12, 11, 'myjob', 'x', 'serverOnly', {})
    T.near(G.Rempart.Punish.currentScore(P), 60, 0.01, 'source réseau ignorée')
end)

return T.finish()
