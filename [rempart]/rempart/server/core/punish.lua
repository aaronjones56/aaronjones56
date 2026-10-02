--[[
    Rempart — moteur de détection et de sanction.

    Rempart.Detect(src, id, details, opts)
      src     : id serveur du joueur
      id      : identifiant de détection (server/core/catalog.lua)
      details : table de preuves (affichée dans les logs/Discord/ban)
      opts    : { score = n (surcharge), screenshot = bool, reason = string }

    Pipeline : catalogue -> immunité -> amortissement des répétitions -> score
    (décroissance exponentielle) -> journalisation -> décision (log/score/kick/ban)
    -> quarantaine -> capture d'écran -> sanction.
]]

local Punish = {}
Rempart.Punish = Punish

local LN2 = math.log(2)

--- Score courant (décroissance exponentielle appliquée).
function Punish.currentScore(P)
    local now = Rempart.now()
    local r = P.risk
    local dt = (now - r.ts) / 1000.0
    if dt > 0 then
        r.score = r.score * math.exp(-LN2 * dt / Config.Risk.halfLife)
        r.ts = now
    end
    return r.score
end

local function addScore(P, points)
    Punish.currentScore(P)
    P.risk.score = P.risk.score + points
    return P.risk.score
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Présentation
-- ─────────────────────────────────────────────────────────────────────────────

local function detailsText(details, maxLen)
    if type(details) ~= 'table' then return tostring(details or '') end
    local parts = {}
    for _, k in ipairs(Utils.keys(details)) do
        local v = details[k]
        if type(v) == 'table' then
            local ok, enc = pcall(json.encode, v)
            v = ok and enc or '?'
        elseif type(v) == 'number' and math.type(v) == 'float' then
            v = Utils.round(v, 2)
        end
        parts[#parts + 1] = ('%s=%s'):format(k, tostring(v))
    end
    return Utils.truncate(table.concat(parts, ' | '), maxLen or 900)
end
Punish.detailsText = detailsText

local function identityFields(P)
    local ids = P.ids
    local discord = ids.discord and ('<@%s>'):format(ids.discord:sub(9)) or '—'
    return {
        { name = 'License', value = '`' .. (ids.license or '—') .. '`', inline = false },
        { name = 'Discord', value = discord, inline = true },
        { name = 'Steam', value = ids.steam or '—', inline = true },
        { name = 'FiveM', value = ids.fivem or '—', inline = true },
        { name = 'Tokens HWID', value = tostring(#P.tokens), inline = true },
    }
end

local function notifyAdmins(msg)
    if not Config.Permissions.notifyAdmins then return end
    if GetResourceState('chat') ~= 'started' then return end
    for src, P in Rempart.Players.each() do
        if P.admin or P.txAdmin then
            TriggerClientEvent('chat:addMessage', src, { args = { msg } })
        end
    end
end
Punish.notifyAdmins = notifyAdmins

local function historyText(P, n)
    local list = P.hist:list()
    local lines = {}
    for i = math.max(1, #list - (n or 8) + 1), #list do
        local h = list[i]
        lines[#lines + 1] = ('`%s` %s (+%s)'):format(os.date('%H:%M:%S', h.t), Rempart.label(h.id), tostring(h.pts))
    end
    return #lines > 0 and table.concat(lines, '\n') or '—'
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Sanctions
-- ─────────────────────────────────────────────────────────────────────────────

local function quarantine(P)
    P.quarantined = true
    if Config.Punish.quarantine then
        TriggerEvent(Rempart.EV_SHIELD .. ':quarantine', P.src, true)
    end
end

local function requestTrail(P)
    TriggerEvent(Rempart.EV_SENSOR .. ':dump', P.src)
end

--- Bannit un joueur connecté. opts : reason, duration, detection, details, by, screenshot
function Punish.ban(P, opts)
    if P.punished then return end
    P.punished = true
    quarantine(P)
    requestTrail(P)
    opts = opts or {}

    local function apply(attachment)
        local details = opts.details or {}
        details.history = {}
        for _, h in ipairs(P.hist:list()) do
            details.history[#details.history + 1] = { id = h.id, t = h.t, pts = h.pts }
        end
        if P.state.sensorTrail then details.trail = P.state.sensorTrail end

        local ban = Rempart.Bans.add({
            name = P.name,
            reason = opts.reason or L('ban_generic'),
            detection = opts.detection,
            details = details,
            identifiers = P.idList,
            tokens = P.tokens,
            duration = opts.duration or 0,
            by = opts.by or 'Rempart',
        })

        Rempart.Log.warn('BAN %s — %s (#%d) : %s [%s]', ban.id, P.name, P.src, ban.reason, opts.detection or 'manuel')
        Rempart.Log.file('ban', { ban = ban.id, src = P.src, name = P.name, reason = ban.reason,
            detection = opts.detection, ids = P.idList, tokens = P.tokens, by = ban.by })

        local fields = {
            { name = 'Ban', value = '`' .. ban.id .. '`', inline = true },
            { name = 'Durée', value = (ban.expiresAt == 0) and L('expires_never') or Utils.formatDuration(opts.duration, Config.Locale), inline = true },
            { name = 'Par', value = ban.by, inline = true },
            { name = 'Détection', value = opts.detection and Rempart.label(opts.detection) or '—', inline = false },
            { name = 'Preuves', value = detailsText(opts.details, 1000), inline = false },
            { name = 'Historique récent', value = historyText(P, 8), inline = false },
        }
        for _, f in ipairs(identityFields(P)) do fields[#fields + 1] = f end
        Rempart.Log.discord('bans', Rempart.Log.embed({
            title = ('⛔ Bannissement — %s (#%d)'):format(P.name, P.src),
            description = ('**Raison :** %s'):format(Utils.escapeMarkdown(ban.reason)),
            color = Rempart.Log.colors.critical,
            fields = fields,
        }), (Config.Logs.discord.mentionOnBan ~= '' and Config.Logs.discord.mentionOnBan) or nil, attachment)

        notifyAdmins(L('notify_action', P.name, P.src, L('action_ban'), ban.reason))
        SetTimeout(Config.Punish.dropDelay or 500, function()
            if GetPlayerName(P.src) then DropPlayer(P.src, Rempart.Bans.message(ban)) end
        end)
        TriggerEvent(Rempart.res .. ':banned', P.src, ban)
    end

    if (opts.screenshot ~= false) and Config.Punish.screenshot then
        Rempart.Screenshot.capture(P.src, apply, true)
    else
        apply(nil)
    end
end

--- Expulse un joueur connecté.
function Punish.kick(P, reason, opts)
    if P.punished then return end
    P.punished = true
    quarantine(P)
    opts = opts or {}
    reason = reason or L('kick_generic')

    local function apply(attachment)
        Rempart.Log.warn('KICK %s (#%d) : %s', P.name, P.src, reason)
        Rempart.Log.file('kick', { src = P.src, name = P.name, reason = reason, detection = opts.detection, by = opts.by })
        local fields = {
            { name = 'Détection', value = opts.detection and Rempart.label(opts.detection) or '—', inline = false },
            { name = 'Historique récent', value = historyText(P, 6), inline = false },
        }
        for _, f in ipairs(identityFields(P)) do fields[#fields + 1] = f end
        Rempart.Log.discord('bans', Rempart.Log.embed({
            title = ('👢 Expulsion — %s (#%d)'):format(P.name, P.src),
            description = ('**Raison :** %s'):format(Utils.escapeMarkdown(reason)),
            color = Rempart.Log.colors.danger,
            fields = fields,
        }), nil, attachment)
        notifyAdmins(L('notify_action', P.name, P.src, L('action_kick'), reason))
        SetTimeout(Config.Punish.dropDelay or 500, function()
            if GetPlayerName(P.src) then DropPlayer(P.src, L('kicked', Config.ServerName, reason)) end
        end)
    end

    if opts.screenshot and Config.Punish.screenshot then
        Rempart.Screenshot.capture(P.src, apply, true)
    else
        apply(nil)
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Détection
-- ─────────────────────────────────────────────────────────────────────────────

local function severityColor(points, action)
    if action == 'ban' or points >= 50 then return Rempart.Log.colors.critical end
    if action == 'kick' or points >= 25 then return Rempart.Log.colors.danger end
    return Rempart.Log.colors.warn
end

--- Point d'entrée unique de toutes les détections.
--- @return string|nil action effectivement retenue ('log','score','warn','kick','ban','audit','immune')
function Rempart.Detect(src, id, details, opts)
    opts = opts or {}
    local def = Rempart.Detections[id]
    if not def then
        details = details or {}
        details.detection = id
        def = Rempart.Detections.custom
        id = 'custom'
    end
    if not def.enabled then return nil end

    local P = Rempart.Players.ensure(src)
    if not P then return nil end
    if P.punished then return nil end
    if Rempart.Perms.immune(P, def) then
        Rempart.Log.debug('Immunité : %s (#%d) pour %s', P.name, P.src, id)
        return 'immune'
    end

    -- Amortissement des répétitions dans la fenêtre de recharge.
    local now = Rempart.now()
    local base = opts.score or def.score or 0
    local c = P.dcount[id]
    local repeated = false
    if c and (now - c.last) < (def.cooldown or 0) * 1000 then
        c.n = c.n + 1
        repeated = true
    else
        c = { n = 0, total = (c and c.total) or 0 }
        P.dcount[id] = c
    end
    c.last = now
    c.total = c.total + 1
    local points = Utils.round(base * (Config.Risk.repeatFactor ^ math.min(c.n, 8)), 1)

    local score = (def.action == 'log') and Punish.currentScore(P) or addScore(P, points)
    P.hist:push({ id = id, t = os.time(), pts = points })

    -- Journalisation
    local dtext = detailsText(details, 600)
    Rempart.Log.info('^3%s^7 %s (#%d) +%s → %d  ^8%s', Rempart.label(id), P.name, P.src, tostring(points), math.floor(score), dtext)
    Rempart.Log.file('detection', { src = P.src, name = P.name, license = P.ids.license, id = id,
        points = points, score = Utils.round(score, 1), details = details, repeated = repeated })

    if not repeated and (points >= Config.Logs.discord.minScore or def.action == 'kick' or def.action == 'ban') then
        local fields = {
            { name = 'Joueur', value = ('%s (#%d)'):format(Utils.escapeMarkdown(P.name), P.src), inline = true },
            { name = 'Score', value = ('+%s → **%d** / %d'):format(tostring(points), math.floor(score), Config.Risk.ban), inline = true },
            { name = 'Preuves', value = dtext ~= '' and ('```%s```'):format(dtext) or '—', inline = false },
            { name = 'License', value = '`' .. (P.ids.license or '—') .. '`', inline = false },
        }
        Rempart.Log.discord('detections', Rempart.Log.embed({
            title = '🛡️ ' .. Rempart.label(id),
            color = severityColor(points, def.action),
            fields = fields,
        }))
    end
    if not repeated and (points >= Config.Permissions.notifyMinScore or def.action ~= 'score') then
        notifyAdmins(L('notify_detection', P.name, P.src, Rempart.label(id), tostring(points), math.floor(score)))
    end

    -- Décision
    local action = def.action
    if action == 'log' then return 'log' end
    if action == 'score' then
        if score >= Config.Risk.ban then
            action = 'ban'
        elseif score >= Config.Risk.kick then
            action = 'kick'
        elseif score >= Config.Risk.warn then
            if not P.warnedAt or (now - P.warnedAt) > 300000 then
                P.warnedAt = now
                notifyAdmins(L('notify_action', P.name, P.src, L('action_warn'), Rempart.label(id)))
                Rempart.Log.discord('admin', Rempart.Log.embed({
                    title = ('⚠️ Joueur à surveiller — %s (#%d)'):format(P.name, P.src),
                    description = ('Score de risque **%d** (alerte à %d, ban à %d)'):format(math.floor(score), Config.Risk.warn, Config.Risk.ban),
                    color = Rempart.Log.colors.warn,
                    fields = { { name = 'Historique récent', value = historyText(P, 8) } },
                }))
                return 'warn'
            end
            return 'score'
        else
            return 'score'
        end
    end

    local reason = opts.reason or Rempart.label(id)
    if Config.AuditMode then
        Rempart.Log.warn('AUDIT : %s aurait été appliqué à %s (#%d) — %s', action, P.name, P.src, reason)
        notifyAdmins(L('notify_action', P.name, P.src, L('action_audit', action), reason))
        Rempart.Log.file('audit', { src = P.src, name = P.name, action = action, detection = id })
        return 'audit'
    end

    local wantShot = opts.screenshot or def.screenshot or action == 'ban'
    if action == 'ban' then
        Punish.ban(P, {
            reason = reason, detection = id, details = details,
            duration = def.banDuration or Config.Risk.autoBanDuration or 0,
            screenshot = wantShot,
        })
    else
        Punish.kick(P, reason, { detection = id, screenshot = wantShot })
    end
    return action
end

-- Trace forensique renvoyée par le capteur (rempart_sensor).
AddEventHandler(Rempart.EV_SENSOR .. ':dumpResult', function(src, trail)
    if source ~= '' and tonumber(source) then return end -- uniquement serveur-local
    local P = Rempart.Players.get(src)
    if P and type(trail) == 'table' then P.state.sensorTrail = trail end
end)
