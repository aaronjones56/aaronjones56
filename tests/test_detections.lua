-- Scénarios des modules de détection serveur (simulateur FXServer).
local T = dofile('tests/lib/t.lua')
local F = dofile('tests/mocks/fivem.lua')
local V = F.vector3

local function boot()
    local env = F.new()
    env:loadManifest('[rempart]/rempart', 'server')
    local G = env.G
    G.Config.Punish.screenshot = false
    G.Config.Punish.dropDelay = 0
    G.Config.Client.enabled = false
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

--- Dernières détections d'un joueur (identifiants).
local function detections(G, src)
    local P = G.Rempart.Players.get(src)
    local out = {}
    for _, h in ipairs(P and P.hist:list() or {}) do out[#out + 1] = h.id end
    return out
end

local function has(list, id)
    for _, v in ipairs(list) do if v == id then return true end end
    return false
end

local function wasCanceled(env, name)
    for _, n in ipairs(env.canceled) do if n == name then return true end end
    return false
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Entités
-- ─────────────────────────────────────────────────────────────────────────────

T.case('entités : modèle interdit de script annulé, population ignorée', function()
    local env, G = boot()
    join(env, 1)
    local cage = env:spawnEntity({ type = 3, model = env.joaat('prop_gold_cont_01'), owner = 1, pop = 7, script = 'myres' })
    T.ok(env:trigger('entityCreating', '', cage), 'création annulée')
    T.ok(has(detections(G, 1), 'entity_blacklisted'))

    -- même modèle militaire en population ambiante (Fort Zancudo) : jamais touché
    join(env, 2)
    local rhino = env:spawnEntity({ type = 2, model = env.joaat('rhino'), owner = 2, pop = 2 })
    T.ok(not env:trigger('entityCreating', '', rhino), 'population non annulée')
    T.eq(#detections(G, 2), 0)
end)

T.case('entités : script inconnu (exécuteur) détecté après revérification', function()
    local env, G = boot()
    join(env, 3)
    local veh = env:spawnEntity({ type = 2, model = env.joaat('adder'), owner = 3, pop = 7, script = nil })
    env:trigger('entityCreating', '', veh)
    T.eq(#detections(G, 3), 0, 'pas de conclusion hâtive')
    env:advance(4000)
    T.ok(has(detections(G, 3), 'entity_unknown_script'), 'détecté après 2 revérifications')
    T.ok(env.deleted[#env.deleted] == veh, 'entité supprimée')
end)

T.case('entités : ressource détournée (chat) et objet de tâche attaché toléré', function()
    local env, G = boot()
    join(env, 4)
    local ped = env:spawnEntity({ type = 1, model = env.joaat('a_m_y_skater_01'), owner = 4, pop = 7, script = 'chat' })
    env:trigger('entityCreating', '', ped)
    T.ok(has(detections(G, 4), 'entity_forbidden_res'))

    join(env, 5)
    local para = env:spawnEntity({ type = 3, model = env.joaat('p_parachute1_s'), owner = 5, pop = 7, script = nil,
        attachedTo = env:ped(5) })
    env:trigger('entityCreating', '', para)
    env:advance(4000)
    T.eq(#detections(G, 5), 0, 'parachute (créé par une tâche du jeu) toléré')
end)

T.case('entités : limiteur de débit', function()
    local env, G = boot()
    join(env, 6)
    local canceled = 0
    for _ = 1, 15 do
        local v = env:spawnEntity({ type = 2, model = env.joaat('blista'), owner = 6, pop = 7, script = 'garage' })
        if env:trigger('entityCreating', '', v) then canceled = canceled + 1 end
    end
    T.eq(canceled, 7, 'rafale de 8 véhicules autorisée, 7 refusés')
    T.ok(has(detections(G, 6), 'entity_spam'))
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Explosions
-- ─────────────────────────────────────────────────────────────────────────────

local function explosion(env, sender, etype, x, y, z, extra)
    local ev = { explosionType = etype, posX = x, posY = y, posZ = z, damageScale = 1.0, cameraShake = 1.0,
        isAudible = true, isInvisible = false, ownerNetId = 0 }
    for k, v in pairs(extra or {}) do ev[k] = v end
    return env:trigger('explosionEvent', '', sender, ev)
end

T.case('explosions : type interdit, blame d\'arme, véhicule crédité légitime', function()
    local env, G = boot()
    join(env, 10, { pos = V(0, 0, 70) })
    join(env, 11, { pos = V(5, 0, 70) })
    T.ok(explosion(env, 10, 59, 0, 0, 70), 'canon orbital annulé')
    T.ok(has(detections(G, 10), 'explosion_blocked'))

    -- explosion de voiture créée par le propriétaire (10) mais créditée à 11 : légitime
    local victimNet = env:entity(env:ped(11)).netId
    T.ok(not explosion(env, 10, 7, 2, 0, 70, { ownerNetId = victimNet }), 'explosion de véhicule autorisée')
    T.ok(not has(detections(G, 10), 'explosion_blame'))

    -- grenade créditée à un autre joueur : blame
    T.ok(explosion(env, 10, 0, 2, 0, 70, { ownerNetId = victimNet }), 'grenade attribuée à autrui annulée')
    T.ok(has(detections(G, 10), 'explosion_blame'))
end)

T.case('explosions : explosion posée à distance sur un joueur + spam', function()
    local env, G = boot()
    join(env, 12, { pos = V(0, 0, 70) })
    join(env, 13, { pos = V(1500, 1500, 70) })
    T.ok(explosion(env, 12, 0, 1501, 1500, 70), 'explosion à 2 km sur un joueur annulée')
    T.ok(has(detections(G, 12), 'explosion_remote'))

    join(env, 14, { pos = V(0, 0, 70) })
    local canceled = 0
    for _ = 1, 20 do if explosion(env, 14, 7, 1, 1, 70) then canceled = canceled + 1 end end
    T.eq(canceled, 8, '12 autorisées sur 10 s, 8 refusées')
    T.ok(has(detections(G, 14), 'explosion_spam'))
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Armes, combat, tâches
-- ─────────────────────────────────────────────────────────────────────────────

T.case('armes : don d\'arme à un autre joueur => ban immédiat', function()
    local env, G = boot()
    join(env, 20)
    join(env, 21)
    local canceled = env:trigger('giveWeaponEvent', '', 20, { pedId = env:entity(env:ped(21)).netId,
        weaponType = env.joaat('WEAPON_RPG'), ammo = 999 })
    env:advance(100)
    T.ok(canceled, 'annulé')
    T.ok(G.Rempart.Bans.match({ 'license:lic20' }, {}), 'banni')

    -- don d'arme à un PNJ possédé par un autre client : autorisé
    join(env, 22)
    local npc = env:spawnEntity({ type = 1, model = env.joaat('s_m_y_cop_01'), owner = 23, pop = 7 })
    T.ok(not env:trigger('giveWeaponEvent', '', 22, { pedId = env:entity(npc).netId, weaponType = 1, ammo = 1 }))
end)

T.case('armes : arme interdite en main retirée côté serveur', function()
    local env, G = boot()
    join(env, 24)
    env.players[24].weapon = env.joaat('WEAPON_RAILGUN')
    env:advance(2500)
    T.ok(has(detections(G, 24), 'weapon_blacklisted'))
    T.eq(env.players[24].weapon, 0xA2719263, 'arme retirée')
end)

local function damage(env, shooter, victimSrc, weapon, extra)
    local data = { weaponType = env.joaat(weapon), hitGlobalId = env:entity(env:ped(victimSrc)).netId,
        overrideDefaultDamage = false, weaponDamage = 0 }
    for k, v in pairs(extra or {}) do data[k] = v end
    return env:trigger('weaponDamageEvent', '', shooter, data)
end

T.case('combat : distance impossible annulée, dimension différente', function()
    local env, G = boot()
    join(env, 30, { pos = V(0, 0, 70) })
    join(env, 31, { pos = V(800, 0, 70) })
    T.ok(damage(env, 30, 31, 'WEAPON_PISTOL'), 'pistolet à 800 m annulé')
    T.ok(has(detections(G, 30), 'combat_distance'))
    T.ok(not damage(env, 30, 31, 'WEAPON_HEAVYSNIPER'), 'sniper à 800 m autorisé')

    join(env, 32, { pos = V(5, 0, 70) })
    env.players[32].bucket = 4
    T.ok(damage(env, 30, 32, 'WEAPON_PISTOL'), 'cible dans une autre dimension')
    T.ok(has(detections(G, 30), 'combat_bucket'))
end)

T.case('combat : tir dans le dos (silent aim) et kill aura', function()
    local env, G = boot()
    -- tireur regardant le nord (cap 0) ; cible plein sud à 30 m
    join(env, 33, { pos = V(0, 0, 70), heading = 0.0 })
    join(env, 34, { pos = V(0, -30, 70) })
    damage(env, 33, 34, 'WEAPON_CARBINERIFLE')
    T.ok(has(detections(G, 33), 'combat_angle'), 'cible derrière le tireur')

    join(env, 35, { pos = V(0, 0, 70), heading = 0.0 })
    join(env, 36, { pos = V(0, 30, 70) })
    damage(env, 35, 36, 'WEAPON_CARBINERIFLE')
    T.ok(not has(detections(G, 35), 'combat_angle'), 'cible devant : rien')

    join(env, 37, { pos = V(0, 0, 70) })
    for i = 1, 7 do join(env, 40 + i, { pos = V(i, 5, 70) }) end
    for i = 1, 7 do damage(env, 37, 40 + i, 'WEAPON_PISTOL') end
    T.ok(has(detections(G, 37), 'combat_multitarget'), '7 joueurs touchés en 2 s')
end)

T.case('tâches : éjection d\'un autre joueur bloquée, PNJ autorisé', function()
    local env, G = boot()
    join(env, 50)
    join(env, 51)
    T.ok(env:trigger('clearPedTasksEvent', '', 50, { pedId = env:entity(env:ped(51)).netId, immediately = true }))
    T.ok(has(detections(G, 50), 'task_clear_player'))
    local npc = env:spawnEntity({ type = 1, model = 1, owner = 51, pop = 4 })
    T.ok(not env:trigger('clearPedTasksEvent', '', 50, { pedId = env:entity(npc).netId, immediately = true }))
end)

T.case('projectiles : origine éloignée et attribution à autrui', function()
    local env, G = boot()
    join(env, 52, { pos = V(0, 0, 70) })
    join(env, 53, { pos = V(10, 0, 70) })
    T.ok(env:trigger('startProjectileEvent', '', 52, { weaponHash = env.joaat('WEAPON_RPG'),
        initialPositionX = 300, initialPositionY = 0, initialPositionZ = 90, ownerId = 0 }))
    T.ok(has(detections(G, 52), 'projectile_spawn'))
    T.ok(not env:trigger('startProjectileEvent', '', 53, { weaponHash = env.joaat('WEAPON_RPG'),
        initialPositionX = 10.5, initialPositionY = 0, initialPositionZ = 71, ownerId = env:entity(env:ped(53)).netId }),
        'tir normal autorisé')
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Mouvement & état
-- ─────────────────────────────────────────────────────────────────────────────

T.case('mouvement : téléportation détectée, déclarée tolérée, points appris', function()
    local env, G = boot()
    local P = join(env, 60, { pos = V(0, 0, 70) })
    env:advance(1100)
    env:entity(env:ped(60)).pos = V(2000, 2000, 70)
    env:advance(1100)
    T.ok(has(detections(G, 60), 'teleport'), 'téléportation détectée')

    -- téléportation déclarée par un script légitime (shield)
    local P2 = join(env, 61, { pos = V(0, 0, 70) })
    env:advance(1100)
    P2.decl.teleports[1] = { x = -500, y = 300, z = 40, t = env.now, r = 'housing' }
    env:entity(env:ped(61)).pos = V(-500, 300, 40)
    env:advance(1100)
    T.ok(not has(detections(G, 61), 'teleport'), 'téléportation déclarée tolérée')

    -- point appris : 3 joueurs distincts vers la même destination
    for i = 1, 3 do
        local src = 70 + i
        join(env, src, { pos = V(0, 0, 70) })
        env:advance(1100)
        env:entity(env:ped(src)).pos = V(3000, -1000, 20)
    end
    env:advance(1100)
    T.ok(has(detections(G, 71), 'teleport'), '1er joueur signalé')
    T.ok(not has(detections(G, 73), 'teleport'), '3e joueur : point validé (ascenseur, intérieur…)')
    T.ok(P, 'joueur toujours présent')
end)

T.case('état : godmode exige une preuve de combat (zones sûres sans faux positif)', function()
    local env, G = boot()
    local P = join(env, 80, { pos = V(0, 0, 70) })
    env.players[80].invincible = true
    env:advance(6000)
    T.ok(not has(detections(G, 80), 'godmode'), 'invincible hors combat (zone sûre) : rien')
    join(env, 81, { pos = V(3, 0, 70) })
    for _ = 1, 4 do
        damage(env, 81, 80, 'WEAPON_PISTOL')
        env:advance(1300)
    end
    T.ok(has(detections(G, 80), 'godmode'), 'invincible en plein combat : détecté')
    T.ok(P, 'ok')
end)

T.case('état : modificateur de dégâts, super saut, santé > max', function()
    local env, G = boot()
    join(env, 82)
    env.players[82].dmgMod = 1.0039   -- quantification 8-10 bits : toléré
    env:advance(3000)
    T.ok(not has(detections(G, 82), 'damage_modifier'), 'valeur quantifiée tolérée')

    join(env, 83)
    env.players[83].dmgMod = 5.0
    env:advance(3000)
    T.ok(has(detections(G, 83), 'damage_modifier'))

    join(env, 84)
    env.players[84].superJump = true
    env:advance(3000)
    T.ok(has(detections(G, 84), 'superjump'))

    join(env, 85)
    env:entity(env:ped(85)).health = 1000
    env:advance(6000)
    T.ok(has(detections(G, 85), 'health_overflow'))
end)

T.case('état : invisibilité en mouvement uniquement', function()
    local env, G = boot()
    join(env, 86, { pos = V(0, 0, 70) })
    env:entity(env:ped(86)).visible = false
    env:advance(6000)
    T.ok(not has(detections(G, 86), 'invisible'), 'invisible immobile (sélection de personnage) : rien')
    for i = 1, 6 do
        env:entity(env:ped(86)).pos = V(i * 6, 0, 70)
        env:advance(1000)
    end
    T.ok(has(detections(G, 86), 'invisible'), 'invisible en mouvement : détecté')
end)

T.case('véhicules : réparation client non déclarée', function()
    local env, G = boot()
    join(env, 90)
    local veh = env:spawnEntity({ type = 2, model = 1, owner = 90, pop = 7, repairs = 0 })
    env:entity(env:ped(90)).vehicle = veh
    env:entity(veh).driver = env:ped(90)
    env:advance(3100)
    env:entity(veh).repairs = 1
    env:advance(3100)
    T.ok(has(detections(G, 90), 'vehicle_repair'))
end)

return T.finish()
