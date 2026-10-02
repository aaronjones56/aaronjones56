--[[
    Rempart — rapports du client anti-cheat et déclarations d'intention.

    Les rapports client ne peuvent viser que des détections de la catégorie client
    (un tricheur ne peut que s'auto-dénoncer). Les preuves sont nettoyées et bornées.

    Les déclarations proviennent du shield (inclus dans vos ressources) : quand un
    script LÉGITIME rend le joueur invisible, le téléporte, le rend invincible…, il le
    déclare. Les détections correspondantes l'ignorent alors pendant que la
    déclaration est active. Un exécuteur qui utilise les natives directement ne
    déclare rien et reste détecté.
]]

local Reports = {}
Rempart.Reports = Reports

local CLIENT_DETECTIONS = Utils.set({
    'client_godmode', 'client_spectate', 'client_invisible', 'client_noclip', 'client_freecam',
    'client_vision', 'client_weapon', 'client_vehicle', 'client_tiny_ped', 'client_ragdoll',
    'nui_devtools', 'texture_menu', 'command_injected', 'client_env_tamper', 'lua_menu', 'client_honeypot',
    'client_ammo', 'client_hitbox',
})

local cheatCommands = Utils.set(Lists.CheatCommands, true)

local function sanitize(d)
    local out = {}
    if type(d) ~= 'table' then return out end
    local n = 0
    for k, v in pairs(d) do
        n = n + 1
        if n > 12 then break end
        local tv = type(v)
        if tv == 'string' then
            out[tostring(k):sub(1, 32)] = v:sub(1, 200)
        elseif tv == 'number' or tv == 'boolean' then
            out[tostring(k):sub(1, 32)] = v
        end
    end
    return out
end

Rempart.Channel.on('detect', function(P, payload)
    if type(payload) ~= 'table' or type(payload.id) ~= 'string' then return end
    local id = payload.id
    if not CLIENT_DETECTIONS[id] then return end
    local d = sanitize(payload.d)

    if id == 'command_injected' then
        local res, name = d.resource, type(d.name) == 'string' and d.name:lower() or ''
        if type(res) == 'string' and res ~= '' and not res:find('^_+cfx')
            and not Rempart.Channel.isServerResource(res) then
            -- commande enregistrée par une ressource qui n'existe pas côté serveur
            return Rempart.Detect(P.src, 'resource_injected', { ressource = res, commande = d.name })
        end
        if not cheatCommands[name] then return end
    end

    if id == 'client_honeypot' then
        -- seul un piège réellement armé par le serveur compte, avec son score serveur
        local score = type(d.evenement) == 'string' and Rempart.Events.clientHoneypotScore(d.evenement)
        if not score then return end
        local armed = false
        for _, n in ipairs(Rempart.Events.clientHoneypots()) do
            if n == d.evenement then armed = true break end
        end
        if not armed then return end
        return Rempart.Detect(P.src, id, d, { score = score })
    end

    Rempart.Detect(P.src, id, d)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Déclarations
-- ─────────────────────────────────────────────────────────────────────────────

local FLAG_KINDS = Utils.set({
    'invisible', 'invincible', 'collision', 'frozen', 'spectate', 'camera', 'vision', 'ragdoll',
    'vehiclegod', 'vehiclepower', 'repair', 'superjump', 'heal',
})

Rempart.Channel.on('decl', function(P, payload)
    if type(payload) ~= 'table' then return end
    local now = Rempart.now()
    local st = P.state
    st.declBucket = st.declBucket or Utils.TokenBucket(4, 30, now)
    if not st.declBucket:take(now) then return end

    local k, r = payload.k, type(payload.r) == 'string' and payload.r:sub(1, 64) or '?'
    if k == 'tp' then
        local x, y, z = tonumber(payload.x), tonumber(payload.y), tonumber(payload.z)
        if not (Utils.isFinite(x) and Utils.isFinite(y) and Utils.isFinite(z)) then return end
        local list = P.decl.teleports
        list[#list + 1] = { x = x, y = y, z = z, t = now, r = r }
        if #list > 8 then table.remove(list, 1) end
    elseif FLAG_KINDS[k] then
        P.decl.flags[k] = { v = payload.v == true, r = r, t = now }
    end
end)

--- Une déclaration de type `kind` est-elle active (valeur vraie) ?
function Reports.declared(P, kind, maxAgeMs)
    local f = P.decl.flags[kind]
    if not f or not f.v then return false end
    if maxAgeMs and (Rempart.now() - f.t) > maxAgeMs then return false end
    return true, f.r
end

--- Une téléportation déclarée récente correspond-elle à cette position ?
function Reports.teleportDeclared(P, x, y, z, radius, maxAgeMs)
    local now = Rempart.now()
    for i = #P.decl.teleports, 1, -1 do
        local tp = P.decl.teleports[i]
        if (now - tp.t) <= (maxAgeMs or 8000) and Utils.dist3(tp.x, tp.y, tp.z, x, y, z) <= (radius or 25.0) then
            return true, tp.r
        end
    end
    return false
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Témoins : le shield d'une autre ressource signale l'arrêt du client anti-cheat
-- (message non signé : la clé n'existe que dans le module anti-cheat).
-- ─────────────────────────────────────────────────────────────────────────────

RegisterNetEvent(Rempart.res .. ':w', function(kind, resource)
    local src = tonumber(source)
    local P = src and Rempart.Players.get(src)
    if not P or P.punished or kind ~= 'acstop' then return end
    local now = Rempart.now()
    if P.state.lastWitness and (now - P.state.lastWitness) < 30000 then return end
    P.state.lastWitness = now
    -- l'anti-cheat tourne côté serveur et le client prétend qu'il s'est arrêté ?
    local reporter = type(resource) == 'string' and resource:sub(1, 64) or '?'
    SetTimeout(10000, function()
        if Rempart.Players.get(src) == P and GetPlayerName(src) then
            Rempart.Detect(src, 'witness_stop', { temoin = reporter })
        end
    end)
end)
