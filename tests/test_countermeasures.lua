-- Scénarios des contre-mesures issues de l'étude des cheats en circulation
-- (redENGINE, Eulen, menus Lua, semi-godmode, event blockers, spoofers HWID…).
local T = dofile('tests/lib/t.lua')
local F = dofile('tests/mocks/fivem.lua')
local V = F.vector3

local function boot(resources, tweak)
    local env = F.new({ resources = resources })
    env:loadManifest('[rempart]/rempart', 'server')
    local G = env.G
    G.Config.Punish.screenshot = false
    G.Config.Punish.dropDelay = 0
    if tweak then tweak(G.Config) end
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

local function detections(G, src)
    local P = G.Rempart.Players.get(src)
    local out = {}
    for _, h in ipairs(P and P.hist:list() or {}) do out[#out + 1] = h.id end
    return out
end

local function has(G, src, id)
    for _, v in ipairs(detections(G, src)) do if v == id then return true end end
    return false
end

local function dropped(env, src)
    for _, d in ipairs(env.dropped) do if d.src == src then return d.reason end end
    return nil
end

local function lastClientEvent(env, target, kind)
    for i = #env.clientEvents, 1, -1 do
        local e = env.clientEvents[i]
        if e.name == 'rempart:s' and e.target == target and e.args[1] == kind then return e.args[2] end
    end
    return nil
end

--- Client anti-cheat simulé : poignée de main, messages signés, compteurs d'envoi.
local function client(env, src)
    local c = { seq = 0, tx = 0, txd = 0 }
    env:trigger('rempart:c', src, 'hello', 0, '', { v = '1.1.0', res = { 'rempart' } })
    local init = lastClientEvent(env, src, 'init')
    c.key = init and init.key
    function c.send(kind, payload, extra, blocked)
        c.seq = c.seq + 1
        local mac = env.G.Utils.signature(c.key, kind, c.seq, extra)
        if not blocked then env:trigger('rempart:c', src, kind, c.seq, mac, payload, extra) end
        c.tx = c.tx + 1
        if kind == 'detect' then c.txd = c.txd + 1 end
        return c.seq
    end
    function c.pong()
        local ping = lastClientEvent(env, src, 'ping')
        if ping then c.send('pong', { n = ping.n, rc = 12 }, ping.nonce) end
    end
    --- Attestation : compteurs attestés `t` ; `rx` = instantané du capteur (même séquence).
    function c.attest(t, rx, sensorFirst)
        local seq = c.seq + 1
        if sensorFirst and rx then env:trigger('rempart:sensor:rx', '', src, seq, rx) end
        c.send('att', { t = t, tx = c.tx, txd = c.txd })
        if not sensorFirst and rx then env:trigger('rempart:sensor:rx', '', src, seq, rx) end
    end
    return c
end

local function damage(env, shooter, victimSrc, weapon, extra)
    local data = { weaponType = type(weapon) == 'number' and weapon or env.joaat(weapon),
        hitGlobalId = env:entity(env:ped(victimSrc)).netId, overrideDefaultDamage = false, weaponDamage = 0 }
    for k, v in pairs(extra or {}) do data[k] = v end
    return env:trigger('weaponDamageEvent', '', shooter, data)
end

local function noClient(cfg) cfg.Client.enabled = false end

-- ─────────────────────────────────────────────────────────────────────────────
-- Combat
-- ─────────────────────────────────────────────────────────────────────────────

T.case('combat : dégâts forgés (chute, noyade, fiente démesurée) bloqués', function()
    local env, G = boot(nil, noClient)
    join(env, 1, { pos = V(0, 0, 70) })
    join(env, 2, { pos = V(3, 0, 70) })
    T.ok(damage(env, 1, 2, 'WEAPON_FALL', { silenced = true }), 'chute forgée annulée')
    T.ok(has(G, 1, 'combat_forged'))
    join(env, 5, { pos = V(0, 0, 70) })
    T.ok(damage(env, 5, 2, 2725352035), 'second hash de WEAPON_FALL')
    join(env, 6, { pos = V(0, 0, 70) })
    T.ok(damage(env, 6, 2, 'WEAPON_DROWNING'), 'noyade forgée')
    join(env, 3, { pos = V(0, 0, 70) })
    T.ok(damage(env, 3, 2, 'WEAPON_BIRD_CRAP', { weaponDamage = 131071 }), 'fiente à 131071 de dégâts')
    T.ok(has(G, 3, 'combat_forged'))
    join(env, 4, { pos = V(0, 0, 70) })
    T.ok(not damage(env, 4, 2, 'WEAPON_BIRD_CRAP', { weaponDamage = 5 }), 'fiente ordinaire (ped oiseau) tolérée')
    T.ok(not has(G, 4, 'combat_forged'))
end)

T.case('combat : portée du taser', function()
    local env, G = boot(nil, noClient)
    join(env, 5, { pos = V(0, 0, 70) })
    join(env, 6, { pos = V(40, 0, 70) })
    join(env, 7, { pos = V(8, 0, 70) })
    T.ok(damage(env, 5, 6, 'WEAPON_STUNGUN'), 'taser à 40 m annulé')
    T.ok(has(G, 5, 'combat_distance'))
    T.ok(not damage(env, 5, 7, 'WEAPON_STUNGUN'), 'taser à 8 m autorisé')
end)

T.case('combat : cible hors du champ de la caméra synchronisée (silent aim)', function()
    local env, G = boot(nil, noClient)
    -- ped tourné vers la cible (le contrôle par le cap ne voit rien), caméra plein sud
    join(env, 8, { pos = V(0, 0, 70), heading = 0.0 })
    join(env, 9, { pos = V(0, 40, 70) })
    env.players[8].camYaw = math.rad(180.0)
    damage(env, 8, 9, 'WEAPON_CARBINERIFLE')
    T.ok(has(G, 8, 'combat_camera'), 'caméra opposée à la cible')
    T.ok(not has(G, 8, 'combat_angle'), 'le cap du ped seul ne suffisait pas')

    join(env, 10, { pos = V(0, 0, 70), heading = 0.0 })
    join(env, 11, { pos = V(0, 40, 70) })
    env.players[10].camYaw = math.rad(20.0)   -- léger décalage de visée : normal
    damage(env, 10, 11, 'WEAPON_CARBINERIFLE')
    T.ok(not has(G, 10, 'combat_camera'))

    join(env, 12, { pos = V(0, 0, 70), heading = 0.0 })
    join(env, 13, { pos = V(0, 8, 70) })
    env.players[12].camYaw = math.rad(180.0)
    damage(env, 12, 13, 'WEAPON_CARBINERIFLE')
    T.ok(not has(G, 12, 'combat_camera'), 'bout portant ignoré')
end)

T.case('combat : godmode par immunités (dégâts mortels sans effet)', function()
    local env, G = boot(nil, noClient)
    join(env, 14, { pos = V(0, 0, 70) })
    join(env, 15, { pos = V(5, 0, 70), health = 200 })
    for _ = 1, 2 do
        for _ = 1, 6 do damage(env, 14, 15, 'WEAPON_PISTOL', { weaponDamage = 60 }) end
        env:advance(3500)
    end
    T.ok(has(G, 15, 'godmode_absorb'), 'santé intacte après 2 rafales mortelles')

    -- serveur qui divise les dégâts : la santé baisse quand même => rien
    join(env, 16, { pos = V(0, 0, 70) })
    join(env, 17, { pos = V(5, 0, 70), health = 200 })
    for _ = 1, 2 do
        for _ = 1, 6 do damage(env, 16, 17, 'WEAPON_PISTOL', { weaponDamage = 60 }) end
        env:entity(env:ped(17)).health = env:entity(env:ped(17)).health - 40
        env:advance(3500)
    end
    T.ok(not has(G, 17, 'godmode_absorb'), 'dégâts réduits mais encaissés')

    -- zone sûre déclarée par un script
    join(env, 18, { pos = V(0, 0, 70) })
    local P19 = join(env, 19, { pos = V(5, 0, 70), health = 200 })
    P19.decl.flags.invincible = { v = true, r = 'safezone', t = env.now }
    for _ = 1, 2 do
        for _ = 1, 6 do damage(env, 18, 19, 'WEAPON_PISTOL', { weaponDamage = 60 }) end
        env:advance(3500)
    end
    T.ok(not has(G, 19, 'godmode_absorb'), 'invincibilité déclarée')
end)

T.case('combat : taser sans chute (anti-ragdoll)', function()
    local env, G = boot(nil, noClient)
    join(env, 20, { pos = V(0, 0, 70) })
    join(env, 21, { pos = V(6, 0, 70) })
    for _ = 1, 3 do
        damage(env, 20, 21, 'WEAPON_STUNGUN')
        env:advance(6000)
    end
    T.ok(has(G, 21, 'tazer_ragdoll'), 'jamais au sol après 3 tirs')

    join(env, 22, { pos = V(0, 0, 70) })
    join(env, 23, { pos = V(6, 0, 70) })
    env:entity(env:ped(23)).ragdoll = true
    for _ = 1, 3 do
        damage(env, 22, 23, 'WEAPON_STUNGUN')
        env:advance(6000)
    end
    T.ok(not has(G, 23, 'tazer_ragdoll'), 'chute normale')
end)

T.case('combat : tirs à travers les murs, recoupés et multi-témoins', function()
    local env, G = boot()
    join(env, 24, { pos = V(0, 0, 70) })
    join(env, 25, { pos = V(30, 0, 70) })
    join(env, 26, { pos = V(0, 30, 70) })
    join(env, 27, { pos = V(-30, 0, 70) })
    local c25, c26, c27 = client(env, 25), client(env, 26), client(env, 27)
    -- témoignage sans tir vu par le serveur : ignoré
    c27.send('wit', { a = 24, d = 30 })
    damage(env, 24, 25, 'WEAPON_CARBINERIFLE', { weaponDamage = 10 })
    c25.send('wit', { a = 24, d = 30 })
    T.ok(not has(G, 24, 'combat_wallbang'), 'une seule victime : rien')
    damage(env, 24, 26, 'WEAPON_CARBINERIFLE', { weaponDamage = 10 })
    c26.send('wit', { a = 24, d = 30 })
    T.ok(has(G, 24, 'combat_wallbang'), 'deux victimes distinctes')
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- État du joueur, entités
-- ─────────────────────────────────────────────────────────────────────────────

T.case('état : soin instantané non déclaré (semi-godmode)', function()
    local env, G = boot(nil, noClient)
    join(env, 30)
    env:entity(env:ped(30)).health = 150
    env:advance(3000)
    env:entity(env:ped(30)).health = 200
    env:advance(2600)
    T.ok(has(G, 30, 'health_regen'), '+50 PV en un échantillon')

    local P31 = join(env, 31)
    env:entity(env:ped(31)).health = 150
    env:advance(3000)
    P31.decl.flags.heal = { v = true, r = 'ambulancejob', t = env.now }
    env:entity(env:ped(31)).health = 200
    env:advance(2600)
    T.ok(not has(G, 31, 'health_regen'), 'soin déclaré (medkit)')

    join(env, 32)
    env:entity(env:ped(32)).health = 0
    env:advance(3000)
    env:entity(env:ped(32)).health = 200
    env:advance(2600)
    T.ok(not has(G, 32, 'health_regen'), 'réanimation')
end)

T.case('entités : cage créée sur un joueur éloigné ; ramassables limités', function()
    local env, G = boot(nil, noClient)
    join(env, 33, { pos = V(0, 0, 70) })
    join(env, 34, { pos = V(500, 0, 70) })
    local chair = env.joaat('prop_chair_01a')
    local cage = env:spawnEntity({ type = 3, model = chair, owner = 33, pop = 7, pos = V(501, 1, 70), script = 'myres' })
    T.ok(env:trigger('entityCreating', '', cage), 'objet sur un joueur à 500 m : bloqué')
    T.ok(has(G, 33, 'entity_remote_spawn'))
    local near = env:spawnEntity({ type = 3, model = chair, owner = 33, pop = 7, pos = V(2, 0, 70), script = 'myres' })
    T.ok(not env:trigger('entityCreating', '', near), 'objet à côté du créateur : autorisé')

    join(env, 35, { pos = V(0, 0, 70) })
    local blocked = 0
    for _ = 1, 15 do
        local p = env:spawnEntity({ type = 3, netType = 7, model = env.joaat('prop_money_bag_01'), owner = 35, pop = 7 })
        if env:trigger('entityCreating', '', p) then blocked = blocked + 1 end
    end
    T.ok(blocked >= 4, 'ramassables au-delà de la rafale bloqués : ' .. blocked)
    T.ok(has(G, 35, 'entity_spam'))
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Attestation des événements (exécuteurs en « ressource isolée »)
-- ─────────────────────────────────────────────────────────────────────────────

local function shieldHello(env, res, names)
    env:trigger('rempart:shield:hello', '', res, names)
    env:advance(1100)
end

T.case('attestation : appel attesté normal, appel extérieur détecté', function()
    local env, G = boot()
    shieldHello(env, 'bank', { 'bank:deposit', 'bank:withdraw' })
    T.ok(G.Rempart.Events.attestable('bank:deposit'), 'événement protégé')
    join(env, 40)
    local c = client(env, 40)
    c.attest({}, {})                                              -- référence
    c.attest({ ['bank:deposit'] = 2 }, { ['bank:deposit'] = 2 })  -- 2 dépôts légitimes
    T.ok(not has(G, 40, 'event_unattested'), 'appels attestés')
    c.attest({ ['bank:deposit'] = 2 }, { ['bank:deposit'] = 5 }, true)   -- +3 reçus, 0 attesté
    T.ok(has(G, 40, 'event_unattested'), 'exécuteur détecté (instantané du capteur reçu en premier)')
    -- perte d'événements (limiteur FXServer) : attesté > reçu => rien
    join(env, 41)
    local c41 = client(env, 41)
    c41.attest({}, {})
    c41.attest({ ['bank:withdraw'] = 4 }, { ['bank:withdraw'] = 1 })
    T.ok(not has(G, 41, 'event_unattested'), 'événements perdus : sans gravité')
end)

T.case('attestation : apprentissage (appelant légitime sans shield) et analyse statique', function()
    local unshieldedClient = { state = 'started', files = {
        ['client.lua'] = "RegisterCommand('pay', function() TriggerServerEvent('bank:transfer', 10) end)" },
        meta = { client_script = { 'client.lua' } } }
    local env, G = boot({ oldbank = unshieldedClient })
    shieldHello(env, 'bank', { 'bank:deposit', 'bank:transfer', 'bank:loan' })
    T.ok(not G.Rempart.Events.attestable('bank:transfer'), 'cité par une ressource sans shield : ignoré')
    for i = 1, 4 do
        join(env, 50 + i)
        local c = client(env, 50 + i)
        c.attest({}, {})
        c.attest({}, { ['bank:loan'] = 1 })
    end
    T.ok(has(G, 51, 'event_unattested') and has(G, 52, 'event_unattested'), 'premiers joueurs signalés')
    T.ok(G.Rempart.Events.mixed['bank:loan'], 'appris au 3e joueur distinct')
    T.ok(not has(G, 54, 'event_unattested'), 'plus de signalement ensuite')
end)

T.case('attestation : code client JS/C# d\'une ressource protégée, shield mal placé', function()
    local env, G = boot({
        bankui = { state = 'started', files = { ['client.lua'] = '', ['ui.js'] = "emitNet('bank:pin', 1234)" },
            meta = { shared_script = { '@rempart/shield.lua' }, client_script = { 'client.lua', 'ui.js' } } },
        csres = { state = 'started', files = {},
            meta = { shared_script = { '@rempart/shield.lua' }, client_script = { 'client.net.dll' } } },
        badorder = { state = 'started', files = { ['config.lua'] = '' },
            meta = { shared_script = { 'config.lua', '@rempart/shield.lua' } } },
    })
    shieldHello(env, 'bankui', { 'bank:pin', 'bank:card' })
    shieldHello(env, 'csres', { 'cs:pay' })
    local E = G.Rempart.Events
    T.ok(not E.attestable('bank:pin'), 'déclenché depuis du JS (non compté par le shield)')
    T.ok(E.attestable('bank:card'), 'déclenché uniquement depuis le Lua protégé')
    T.ok(not E.attestable('cs:pay'), 'ressource avec client C# : exclue')
    T.ok(E.misplacedShields.badorder, 'shield après config.lua : signalé')
    T.ok(not E.misplacedShields.bankui, 'shield en premier : correct')
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Event blocker, resource blocker
-- ─────────────────────────────────────────────────────────────────────────────

T.case('canal : rapports de détection bloqués par le client (event blocker)', function()
    local env, G = boot()
    join(env, 60)
    local c = client(env, 60)
    c.send('detect', { id = 'client_godmode', d = {} }, nil, true)   -- bloqué par le cheat
    c.send('detect', { id = 'client_noclip', d = {} }, nil, true)
    c.send('pong', { n = 0, rc = 1 }, 'x')                            -- le heartbeat passe
    c.attest({}, nil)
    T.ok(has(G, 60, 'client_blocked'), 'seules les détections manquent')

    join(env, 61)
    local c61 = client(env, 61)
    c61.send('decl', { k = 'camera', v = true, r = 'x' }, nil, true)   -- perte « aveugle »
    c61.attest({}, nil)
    T.ok(not has(G, 61, 'client_blocked'), 'perte non ciblée : pas de sanction')
end)

T.case('canal : attestations filtrées alors que le heartbeat passe', function()
    local env, G = boot()
    join(env, 62)
    local c = client(env, 62)
    for _ = 1, 4 do
        env:advance(15100)
        c.pong()
    end
    T.ok(has(G, 62, 'client_blocked'))
end)

T.case('client : module anti-cheat bloqué alors que les autres scripts tournent', function()
    local env, G = boot()
    join(env, 63)
    env:trigger('rempart:sensor:hit', '', 63, 'active', {})
    env:advance(95000)
    T.ok((dropped(env, 63) or ''):find('module anti%-cheat'), 'kick après 90 s d\'activité sans anti-cheat')
    join(env, 64)
    env:advance(95000)
    T.eq(dropped(env, 64), nil, 'chargement lent sans activité : encore toléré')
    T.ok(G, 'ok')
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Marqueur de ban (spoofer HWID + nouveau compte)
-- ─────────────────────────────────────────────────────────────────────────────

T.case('cookies : marqueur posé, ban, retour avec un nouveau compte et un PC spoofé', function()
    local env, G = boot()
    join(env, 70)
    local c = client(env, 70)
    c.send('ck', {})
    local set = lastClientEvent(env, 70, 'setck')
    T.ok(set and #set.v == 32, 'nouveau marqueur envoyé')
    local mark = set.v
    G.Rempart.Detect(70, 'resource_injected', { ressources = 'eulen' })
    env:advance(100)
    T.ok((dropped(env, 70) or ''):find('banni'), 'banni')
    local ban = G.Rempart.Bans.match({ 'license:lic70' }, {})
    T.ok(ban and ban.cookies[1] == mark, 'marqueur rattaché au ban')

    -- nouveau compte, tokens matériels changés (spoofer), mais même installation FiveM
    join(env, 71, { ids = { 'license:new71', 'discord:9' }, tokens = { '2:spoofed' } })
    local c71 = client(env, 71)
    c71.send('ck', { k = mark, l = mark })
    env:advance(100)
    T.ok((dropped(env, 71) or ''):find('banni'), 'contournement détecté')
    T.ok(G.Rempart.Bans.match({ 'license:new71' }, {}), 'nouveau compte banni')

    join(env, 72)
    local c72 = client(env, 72)
    c72.send('ck', { l = ('a'):rep(32) })
    local resync = lastClientEvent(env, 72, 'setck')
    T.eq(resync and resync.v, ('a'):rep(32), 'marqueur NUI recopié dans le KVP')
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Pièges : forts, motifs, ressources chiffrées, pièges client
-- ─────────────────────────────────────────────────────────────────────────────

T.case('pièges : prudence avec ressources chiffrées, pièges forts et motif DFWM', function()
    local escrow = { state = 'started', files = { ['sv.lua'] = 'FXAP\0\1binary' }, meta = { server_script = { 'sv.lua' } } }
    local env, G = boot({ paidjob = escrow })
    T.ok(G.Rempart.Events.escrowed.paidjob, 'ressource chiffrée repérée')
    join(env, 80)
    env:trigger('rempart:sensor:hit', '', 80, 'honeypot', { event = 'esx_truckerjob:pay', size = 20 })
    env:advance(100)
    T.eq(dropped(env, 80), nil, 'piège classique dégradé en score')
    T.ok(has(G, 80, 'event_honeypot'))

    join(env, 81)
    env:trigger('rempart:sensor:hit', '', 81, 'honeypot', { event = 'antilynx8:anticheat', size = 20 })
    env:advance(100)
    T.ok((dropped(env, 81) or ''):find('banni'), 'piège fort : ban')

    join(env, 82)
    env:trigger('rempart:sensor:hit', '', 82, 'honeypot', { event = 'esx_pizza:pDFWMay', size = 20, pattern = 'DFWM' })
    env:advance(100)
    T.ok((dropped(env, 82) or ''):find('banni'), 'motif DFWM : ban')
end)

T.case('pièges client : armés seulement si la ressource visée est absente', function()
    local env, G = boot({ es_extended = { state = 'started', files = {}, meta = {} } })
    local armed = {}
    for _, n in ipairs(G.Rempart.Events.clientHoneypots()) do armed[n] = true end
    T.ok(not armed['esx:getSharedObject'], 'ESX présent : sondage légitime')
    T.ok(armed['QBCore:GetObject'], 'QBCore absent : piège armé')
    join(env, 83)
    local c = client(env, 83)
    c.send('detect', { id = 'client_honeypot', d = { evenement = 'esx:getSharedObject' } })
    T.ok(not has(G, 83, 'client_honeypot'), 'piège non armé : ignoré')
    c.send('detect', { id = 'client_honeypot', d = { evenement = 'HCheat:TempDisableDetection' } })
    env:advance(100)
    T.ok(has(G, 83, 'client_honeypot'), 'piège armé : signalé avec le score serveur (80)')
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Capteur (rempart_sensor) : comptage pour l'attestation, motifs, activité
-- ─────────────────────────────────────────────────────────────────────────────

T.case('capteur : instantané des événements protégés au passage d\'une attestation', function()
    local env = F.new({ resource = 'rempart_sensor' })
    local G = env.G
    G.Citizen.SetEventRoutine = function(fn) env.routine = fn end
    G.RegisterResourceAsEventHandler = function() end
    env:load('[rempart]/rempart_sensor/sensor.lua')
    local hits, snaps = {}, {}
    G.AddEventHandler('rempart:sensor:hit', function(src, kind, data) hits[#hits + 1] = { src = src, kind = kind, data = data } end)
    G.AddEventHandler('rempart:sensor:rx', function(src, seq, counts) snaps[#snaps + 1] = { src = src, seq = seq, counts = counts } end)
    local pack = G.msgpack.pack_args
    env.routine('rempart:sensor:config', pack({
        honeypots = {}, patterns = { 'DFWM' }, known = { ['bank:deposit'] = 'bank' }, prefixes = {}, escrowed = {},
        flood = 35, burst = 40, maxPayload = 262144, unknown = false, joinGrace = 0,
        tracked = { ['bank:deposit'] = true }, channel = 'rempart:c', ignore = { ['rempart:c'] = true },
    }), '')
    for _ = 1, 3 do env.routine('bank:deposit', pack(100), 'net:5') end
    env.routine('chat:msg', pack('salut'), 'net:5')
    env.routine('rempart:c', pack('att', 7, 'mac', {}, nil), 'net:5')
    T.eq(#snaps, 1, 'un instantané')
    T.eq(snaps[1].seq, 7)
    T.eq(snaps[1].counts['bank:deposit'], 3, 'événements protégés comptés')
    T.eq(snaps[1].counts['chat:msg'], nil, 'événements non protégés ignorés')
    local active = 0
    for _, h in ipairs(hits) do if h.kind == 'active' then active = active + 1 end end
    T.eq(active, 1, 'activité signalée une seule fois')
    env.routine('esx_pizza:pDFWMay', pack(1), 'net:5')
    local last = hits[#hits]
    T.ok(last.kind == 'honeypot' and last.data.pattern == 'DFWM', 'motif DFWM')
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Shield côté client : compteurs, menus Lua, soins déclarés
-- ─────────────────────────────────────────────────────────────────────────────

T.case('shield client : compteurs d\'attestation, menu Lua injecté, soin déclaré', function()
    local env = F.new({ resource = 'myjob' })
    local G = env.G
    env:addPlayer(1, { health = 150 })
    G.IsDuplicityVersion = function() return false end
    G.PlayerPedId = function() return env:ped(1) end
    G.PlayerId = function() return 0 end
    G.GetVehiclePedIsIn = function() return 0 end
    local sent = {}
    G.TriggerServerEvent = function(name) sent[#sent + 1] = name end
    G.SetEntityHealth = function(e, h) env.entities[e].health = h end
    local declared, reports = {}, {}
    env.exportsTable.rempart = {
        Declare = function(kind, value) declared[#declared + 1] = { kind = kind, value = value } end,
        ShieldGlobals = function() return { 'LynxEvo', 'HamMafia' } end,
        ShieldReport = function(kind, data) reports[#reports + 1] = { kind = kind, data = data } end,
    }
    env:load('[rempart]/rempart/shield.lua')

    for _ = 1, 3 do G.TriggerServerEvent('myjob:pay', 50) end
    G.TriggerServerEvent('myjob:bonus')
    T.eq(#sent, 4, 'événements toujours envoyés')
    local counts = env.exportsTable.myjob.__rmp_tx()
    T.eq(counts['myjob:pay'], 3)
    T.eq(counts['myjob:bonus'], 1)

    G.SetEntityHealth(env:ped(1), 200)
    T.ok(declared[#declared] and declared[#declared].kind == 'heal', 'soin déclaré')
    T.eq(env:entity(env:ped(1)).health, 200, 'native d\'origine appelée')

    env:advance(25000)
    T.eq(#reports, 0, 'environnement sain')
    G.HamMafia = {}     -- un exécuteur injecte un menu dans cette ressource
    env:advance(31000)
    T.ok(reports[1] and reports[1].data.variable == 'HamMafia', 'menu Lua repéré dans la ressource')
end)

T.case('shield serveur : annonce de ses événements réseau, y compris tardifs', function()
    local env = F.new({ resource = 'myjob' })
    local G = env.G
    env:load('[rempart]/rempart/shield.lua')
    local hello, late
    G.AddEventHandler('rempart:shield:hello', function(res, names) hello = { res = res, names = names } end)
    G.AddEventHandler('rempart:shield:net', function(res, name) late = { res = res, name = name } end)
    G.RegisterNetEvent('myjob:pay', function() end)
    env:trigger('onResourceStart', '', 'rempart')
    env:advance(1100)
    T.ok(hello and hello.res == 'myjob' and hello.names[1] == 'myjob:pay', 'annonce initiale')
    G.RegisterNetEvent('myjob:late', function() end)
    T.ok(late and late.name == 'myjob:late', 'événement enregistré après l\'annonce')
end)

return T.finish()
