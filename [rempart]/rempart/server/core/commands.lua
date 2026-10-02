--[[
    Rempart — commandes d'administration : `rmp <sous-commande>` (console serveur ou chat).
    Permission : ACE Config.Permissions.admin (la console est toujours autorisée).
]]

local Commands = {}
Rempart.Commands = Commands

local function reply(src, msg)
    if src == 0 then
        print('^5[Rempart]^7 ' .. msg)
    else
        for line in tostring(msg):gmatch('[^\n]+') do
            TriggerClientEvent('chat:addMessage', src, { args = { '^5Rempart', line } })
        end
    end
end

local function adminName(src)
    if src == 0 then return 'console' end
    local P = Rempart.Players.get(src)
    return P and P.name or ('#' .. src)
end

local function playerSummary(P)
    local score = Rempart.Punish.currentScore(P)
    local lines = {
        ('%s (#%d) — risque %.1f / %d%s%s'):format(P.name, P.src, score, Config.Risk.ban,
            P.bypass and ' [bypass]' or '', P.txAdmin and ' [txAdmin]' or ''),
        ('license : %s | discord : %s | tokens : %d'):format(P.ids.license or '—', P.ids.discord or '—', #P.tokens),
        ('session AC : %s%s'):format(P.session and 'active' or 'aucune',
            P.session and P.session.rtt and (' (rtt %d ms)'):format(P.session.rtt) or ''),
    }
    local hist = P.hist:list()
    for i = math.max(1, #hist - 9), #hist do
        local h = hist[i]
        lines[#lines + 1] = ('  %s  %s (+%s)'):format(os.date('%H:%M:%S', h.t), Rempart.label(h.id), tostring(h.pts))
    end
    return table.concat(lines, '\n')
end

local sub = {}

sub.help = function(src)
    reply(src, table.concat({
        'Commandes Rempart :',
        '  rmp status | rmp player <id> | rmp kick <id> <raison>',
        '  rmp ban <id|identifiant> <durée|perm> <raison> | rmp unban <ban|identifiant>',
        '  rmp baninfo <ban> | rmp bans [recherche] | rmp screenshot <id>',
        '  rmp exempt <id> <détection|catégorie|all> <durée> | rmp reset <id>',
        '  rmp observe on|off (mode audit) | rmp audit | rmp scan | rmp shield | rmp events | rmp stats',
        'Durées : 30m, 12h, 7d, 2w, perm',
    }, '\n'))
end

sub.status = function(src)
    local covered = Rempart.Events.shieldCoverage()
    reply(src, ('Rempart v%s | joueurs %d | bans %d (%s) | mode audit %s | capteur %s | shields %d | pièges %d'):format(
        Rempart.version, Rempart.Players.count(), Rempart.Bans.count(), Rempart.Storage.backend,
        Config.AuditMode and L('on') or L('off'), Rempart.Events.sensorOnline and 'en ligne' or 'absent',
        #covered, Utils.count(Rempart.Events.honeypots)))
end

sub.player = function(src, args)
    local P = Rempart.Players.find(args[1])
    if not P then return reply(src, L('cmd_player_not_found', tostring(args[1]))) end
    reply(src, playerSummary(P))
end

sub.kick = function(src, args)
    local P = Rempart.Players.find(args[1])
    if not P then return reply(src, L('cmd_player_not_found', tostring(args[1]))) end
    local reason = table.concat(args, ' ', 2)
    Rempart.Punish.kick(P, reason ~= '' and reason or L('kick_generic'), { by = adminName(src) })
    reply(src, L('cmd_kicked', P.name))
end

sub.ban = function(src, args)
    if #args < 2 then return reply(src, L('cmd_usage', 'rmp ban <id|identifiant> <durée|perm> <raison>')) end
    local duration = Utils.parseDuration(args[2])
    if not duration then return reply(src, L('cmd_usage', 'durée : 30m, 12h, 7d, 2w, perm')) end
    local reason = table.concat(args, ' ', 3)
    if reason == '' then reason = L('ban_generic') end
    local by = adminName(src)
    local P = Rempart.Players.find(args[1])
    if P then
        Rempart.Punish.ban(P, { reason = reason, duration = duration, by = by, screenshot = false })
        local ban = Rempart.Bans.match(P.idList, P.tokens)
        return reply(src, L('cmd_banned', ban and ban.id or '?', P.name, Utils.formatDuration(duration, Config.Locale)))
    end
    if not tostring(args[1]):find(':') then return reply(src, L('cmd_player_not_found', tostring(args[1]))) end
    local ban = Rempart.Bans.add({ name = '(hors ligne)', reason = reason, identifiers = { args[1] }, duration = duration, by = by })
    Rempart.Log.file('ban', { ban = ban.id, offline = true, ids = { args[1] }, by = by, reason = reason })
    reply(src, L('cmd_banned', ban.id, args[1], Utils.formatDuration(duration, Config.Locale)))
end

sub.unban = function(src, args)
    local q = args[1]
    if not q then return reply(src, L('cmd_usage', 'rmp unban <ban|identifiant>')) end
    local ban = Rempart.Bans.get(q) or Rempart.Bans.match({ q }, { q })
    if not ban then return reply(src, L('cmd_ban_not_found', q)) end
    Rempart.Bans.remove(ban.id)
    Rempart.Log.file('unban', { ban = ban.id, by = adminName(src) })
    Rempart.Log.discord('admin', Rempart.Log.embed({
        title = '✅ Débannissement', description = ('Ban `%s` (%s) levé par %s'):format(ban.id, ban.name, adminName(src)),
        color = Rempart.Log.colors.ok,
    }))
    reply(src, L('cmd_unbanned', ban.id))
end

sub.baninfo = function(src, args)
    local ban = args[1] and Rempart.Bans.get(args[1])
    if not ban then return reply(src, L('cmd_ban_not_found', tostring(args[1]))) end
    reply(src, ('%s — %s\nraison : %s\npar : %s le %s\nexpire : %s\ndétection : %s | contournements : %d\nidentifiants : %s\ntokens : %d')
        :format(ban.id, ban.name, ban.reason, ban.by, os.date('%d/%m/%Y %H:%M', ban.createdAt), Rempart.Bans.expiryText(ban),
            ban.detection and Rempart.label(ban.detection) or '—', ban.evasions or 0,
            table.concat(ban.identifiers, ', '), #(ban.tokens or {})))
end

sub.bans = function(src, args)
    local list = Rempart.Bans.search(table.concat(args, ' '), 15)
    if #list == 0 then return reply(src, L('cmd_ban_not_found', table.concat(args, ' '))) end
    local lines = {}
    for _, b in ipairs(list) do
        lines[#lines + 1] = ('%s | %s | %s | %s'):format(b.id, b.name, os.date('%d/%m/%y', b.createdAt), Utils.truncate(b.reason, 50))
    end
    reply(src, table.concat(lines, '\n'))
end

sub.screenshot = function(src, args)
    local P = Rempart.Players.find(args[1])
    if not P then return reply(src, L('cmd_player_not_found', tostring(args[1]))) end
    Rempart.Screenshot.capture(P.src, function(att)
        if not att then return reply(src, 'Capture impossible (screenshot-basic absent ou délai dépassé).') end
        Rempart.Log.discord('admin', Rempart.Log.embed({
            title = ('📸 Capture de %s (#%d)'):format(P.name, P.src),
            description = ('Demandée par %s'):format(adminName(src)),
        }), nil, att)
    end, true)
    reply(src, L('cmd_screenshot', P.name))
end

sub.exempt = function(src, args)
    local P = Rempart.Players.find(args[1])
    if not P then return reply(src, L('cmd_player_not_found', tostring(args[1]))) end
    local key = args[2] or 'all'
    local duration = Utils.parseDuration(args[3] or '10m') or 600
    Rempart.Perms.exempt(P, key, duration)
    reply(src, L('cmd_exempt', key, P.name, Utils.formatDuration(duration, Config.Locale)))
end

sub.reset = function(src, args)
    local P = Rempart.Players.find(args[1])
    if not P then return reply(src, L('cmd_player_not_found', tostring(args[1]))) end
    P.risk.score, P.risk.ts, P.dcount = 0.0, Rempart.now(), {}
    reply(src, L('cmd_reset', P.name))
end

sub.observe = function(src, args)
    local v = args[1] and args[1]:lower()
    if v == 'on' then Config.AuditMode = true elseif v == 'off' then Config.AuditMode = false end
    reply(src, L('cmd_audit', Config.AuditMode and L('on') or L('off')))
end

sub.audit = function(src)
    local score = Rempart.Audit.report()
    reply(src, ('Audit de sécurité : %d/100 (détails en console serveur).'):format(score))
end

sub.scan = function(src)
    reply(src, 'Analyse des ressources lancée…')
    Rempart.Scanner.run(function(findings)
        reply(src, ('Analyse terminée : %d alerte(s) (détails en console serveur).'):format(#findings))
    end)
end

sub.shield = function(src)
    local covered, missing = Rempart.Events.shieldCoverage()
    reply(src, ('Shield actif dans %d ressource(s). Sans shield (%d) : %s'):format(#covered, #missing,
        Utils.truncate(table.concat(missing, ', '), 600)))
end

sub.events = function(src)
    local E = Rempart.Events
    reply(src, ('Événements réseau recensés : %d | préfixes dynamiques : %d | ressources chiffrées : %d | pièges armés : %d | capteur : %s')
        :format(Utils.count(E.registry), Utils.count(E.prefixes), Utils.count(E.escrowed), Utils.count(E.honeypots),
            E.sensorOnline and 'en ligne' or 'absent'))
end

sub.stats = function(src)
    local lines = { 'Entités créées par ressource (depuis le démarrage) :' }
    local stats = Rempart.modulesByName.entities.stats
    for _, res in ipairs(Utils.keys(stats)) do
        local s = stats[res]
        lines[#lines + 1] = ('  %s : %d véhicules, %d peds, %d objets'):format(res, s.vehicle, s.ped, s.object)
    end
    lines[#lines + 1] = ('Points de téléportation appris : %d'):format(#Rempart.Movement.points())
    reply(src, table.concat(lines, '\n'))
end

RegisterCommand('rmp', function(source, args)
    local src = tonumber(source) or 0
    if not Rempart.Perms.isAdmin(src) then
        return reply(src, L('cmd_no_permission'))
    end
    local name = (args[1] or 'help'):lower()
    table.remove(args, 1)
    local fn = sub[name] or sub.help
    local ok, err = pcall(fn, src, args)
    if not ok then
        reply(src, 'Erreur : ' .. tostring(err))
        Rempart.Log.error('Commande rmp %s : %s', name, tostring(err))
    end
end, false)
