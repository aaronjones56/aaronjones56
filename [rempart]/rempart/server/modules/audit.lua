--[[
    Module : audit de sécurité du serveur (au démarrage + commande `rmp audit`).
    Vérifie les convars de sécurité documentées par Cfx.re, les ACL dangereuses
    et l'environnement de Rempart. Rien n'est modifié sans Config.Audit.autoHarden.
]]

local M = Rempart.module('audit', {})
Rempart.Audit = M

local function cv(name, default) return GetConvar(name, default or '') end
local function cvi(name, default) return GetConvarInt(name, default or 0) end
local function truthy(v) v = tostring(v):lower() return v == 'true' or v == '1' or v == 'yes' or v == 'on' end

--- Exécute l'audit. Retourne la liste des contrôles et le score (/100).
function M.run()
    local checks = {}
    local function add(weight, ok, label, advice)
        checks[#checks + 1] = { weight = weight, ok = ok, label = label, advice = advice }
    end

    local onesync = cv('onesync', 'off')
    add(25, onesync == 'on', ('OneSync : %s'):format(onesync),
        'set onesync on — INDISPENSABLE : la majorité des détections serveur en dépendent')

    add(10, not truthy(cv('sv_scriptHookAllowed', 'false')), 'ScriptHook interdit',
        'set sv_scriptHookAllowed false')

    local lockdown = cv('sv_entityLockdown', 'inactive')
    add(8, lockdown == 'relaxed' or lockdown == 'strict' or lockdown == 'full', ('Entity lockdown : %s'):format(lockdown),
        'set sv_entityLockdown relaxed (testez vos scripts : bloque les entités de script créées par les clients)')

    local filter = cvi('sv_filterRequestControl', 0)
    add(8, filter >= 2, ('Filtre REQUEST_CONTROL : %d'):format(filter),
        'set sv_filterRequestControl 2 (ou 4 si compatible) — empêche la prise de contrôle des véhicules/entités d\'autrui')

    add(5, not truthy(cv('sv_enableNetworkedSounds', 'true')), 'Sons réseau désactivés',
        'set sv_enableNetworkedSounds false — empêche le spam de sons')

    add(4, not truthy(cv('sv_enableNetworkedPhoneExplosions', 'false')), 'Explosions de téléphone réseau désactivées',
        'set sv_enableNetworkedPhoneExplosions false')

    add(4, not truthy(cv('sv_enableNetworkedScriptEntityStates', 'true')), 'États d\'entités de script réseau désactivés',
        'set sv_enableNetworkedScriptEntityStates false (si aucun script n\'en dépend)')

    add(6, truthy(cv('sv_stateBagStrictMode', 'false')), 'State bags en mode strict',
        'setr sv_stateBagStrictMode true — seul le serveur peut écrire les state bags (vérifiez pma-voice & co.)')

    local pure = cvi('sv_pureLevel', 0)
    add(5, pure >= 1, ('Pure level : %d'):format(pure), 'sv_pureLevel 1 — bloque les fichiers de jeu modifiés')

    add(3, truthy(cv('sv_endpointPrivacy', 'false')), 'Confidentialité des IP', 'set sv_endpointPrivacy true')

    add(3, truthy(cv('sv_disableClientReplays', 'false')), 'Replays client désactivés',
        'set sv_disableClientReplays true')

    local rcon = cv('rcon_password', '')
    add(5, rcon == '' or #rcon >= 16, rcon == '' and 'RCON désactivé' or 'Mot de passe RCON robuste',
        'rcon_password : laissez vide (désactivé) ou utilisez 16+ caractères aléatoires')

    local everyone = IsPrincipalAceAllowed('builtin.everyone', 'command')
    add(10, not everyone, 'builtin.everyone sans accès console',
        'CRITIQUE : un « add_ace builtin.everyone command allow » donne la console à TOUS les joueurs')

    -- Ressources disposant de TOUTES les commandes console (cible de choix pour une backdoor)
    local powerful = {}
    for _, res in ipairs(Rempart.Files.resources(true)) do
        if res ~= Rempart.res and res ~= 'monitor' and IsPrincipalAceAllowed('resource.' .. res, 'command') then
            powerful[#powerful + 1] = res
        end
    end
    add(4, #powerful <= 3, ('Ressources avec accès console total : %d'):format(#powerful),
        (#powerful > 0 and ('Vérifiez : %s'):format(table.concat(powerful, ', ')) or ''))

    add(2, Rempart.res ~= 'rempart', ('Nom de ressource : %s'):format(Rempart.res),
        'Renommez le dossier (ex. « core_utils ») : les « resource stoppers » ciblent les noms connus')

    local anyHook = false
    for _, url in pairs(Rempart.webhooks) do if url ~= '' then anyHook = true end end
    add(2, anyHook, 'Webhooks Discord configurés', 'set rempart_webhook_detections "https://discord.com/api/webhooks/…"')

    add(2, GetResourceState('rempart_sensor') == 'started', 'Capteur rempart_sensor démarré',
        'ensure rempart_sensor (après rempart) — détection des événements-pièges et floods')

    add(1, Rempart.Screenshot.available(), 'screenshot-basic disponible',
        'ensure screenshot-basic — captures d\'écran jointes aux bans')

    local total, got = 0, 0
    for _, c in ipairs(checks) do
        total = total + c.weight
        if c.ok then got = got + c.weight end
    end
    local score = math.floor(got * 100 / total + 0.5)
    return checks, score, powerful
end

--- Affiche le rapport en console (et Discord).
function M.report()
    local checks, score = M.run()
    local color = score >= 80 and '^2' or (score >= 50 and '^3' or '^1')
    print(('^5[Rempart]^7 ════════ Audit de sécurité : %s%d/100^7 ════════'):format(color, score))
    local lines = {}
    for _, c in ipairs(checks) do
        print(('  %s %s^7%s'):format(c.ok and '^2✔' or '^1✘', c.label,
            (not c.ok and c.advice ~= '') and ('\n      ^3→ ' .. c.advice) or ''))
        if not c.ok then lines[#lines + 1] = ('✘ **%s**\n→ %s'):format(c.label, c.advice) end
    end
    for _, w in ipairs(Rempart.configWarnings) do
        print('  ^3⚠ ' .. w .. '^7')
    end
    Rempart.Log.discord('system', Rempart.Log.embed({
        title = ('🧪 Audit de sécurité : %d/100'):format(score),
        description = #lines > 0 and table.concat(lines, '\n') or 'Aucune faiblesse détectée. 👏',
        color = score >= 80 and Rempart.Log.colors.ok or (score >= 50 and Rempart.Log.colors.warn or Rempart.Log.colors.critical),
    }))
    return score
end

--- Durcissement automatique (convars modifiables à chaud, sans risque de casse majeure).
function M.harden()
    local applied = {}
    local function set(name, value)
        if GetConvar(name, '') ~= value then
            SetConvar(name, value)
            applied[#applied + 1] = ('%s %s'):format(name, value)
        end
    end
    set('sv_enableNetworkedSounds', 'false')
    set('sv_enableNetworkedPhoneExplosions', 'false')
    if GetConvarInt('sv_filterRequestControl', 0) < 2 then set('sv_filterRequestControl', '2') end
    if #applied > 0 then
        Rempart.Log.ok('Durcissement appliqué : %s', table.concat(applied, ' | '))
    end
    return applied
end

function M.init()
    if Config.Audit.autoHarden then M.harden() end
    if Config.Audit.onStart then
        SetTimeout(3000, M.report)
    end
end
