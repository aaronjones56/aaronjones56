--[[
    Rempart — journalisation : console, fichiers (JSON lines), Discord.

    Discord : une file par webhook, envoi espacé (≈1 msg / 1.3 s), regroupement
    jusqu'à 5 embeds par message, respect du 429 (retry_after), pièces jointes
    (captures d'écran) en multipart/form-data.
]]

local Log = {}
Rempart.Log = Log

local COLORS = { info = '^5', warn = '^3', error = '^1', debug = '^8', ok = '^2' }
local EMBED_COLORS = { info = 0x3498DB, warn = 0xF1C40F, danger = 0xE67E22, critical = 0xE74C3C, ok = 0x2ECC71 }
Log.colors = EMBED_COLORS

-- ─────────────────────────────────────────────────────────────────────────────
-- Console
-- ─────────────────────────────────────────────────────────────────────────────

local function console(level, msg)
    if not Config.Logs.console and level ~= 'error' then return end
    print(('%s[Rempart]^7 %s^7'):format(COLORS[level] or '', msg))
end

function Log.info(fmt, ...) console('info', select('#', ...) > 0 and fmt:format(...) or fmt) end
function Log.ok(fmt, ...) console('ok', select('#', ...) > 0 and fmt:format(...) or fmt) end
function Log.warn(fmt, ...) console('warn', select('#', ...) > 0 and fmt:format(...) or fmt) end
function Log.error(fmt, ...) console('error', select('#', ...) > 0 and fmt:format(...) or fmt) end
function Log.debug(fmt, ...)
    if Config.Debug then console('debug', select('#', ...) > 0 and fmt:format(...) or fmt) end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Fichiers : logs/AAAA-MM-JJ.log (une ligne JSON par entrée)
-- ─────────────────────────────────────────────────────────────────────────────

local file = { handle = nil, date = nil, disabled = not Config.Logs.file }

local function openLogFile()
    local date = os.date('%Y-%m-%d')
    if file.handle and file.date == date then return file.handle end
    if file.handle then pcall(file.handle.close, file.handle) end
    file.handle, file.date = nil, date

    local base = GetResourcePath(Rempart.res)
    local candidates = {
        ('%s/logs/%s.log'):format(base, date),
        ('@%s/logs/%s.log'):format(Rempart.res, date),
    }
    for _, path in ipairs(candidates) do
        local ok, h = pcall(io.open, path, 'a')
        if ok and h then
            file.handle = h
            return h
        end
    end
    file.disabled = true
    console('warn', 'Journal fichier indisponible (dossier logs/ absent ou non inscriptible) : désactivé.')
    return nil
end

--- Écrit une entrée structurée dans le journal du jour.
function Log.file(kind, data)
    if file.disabled then return end
    local h = openLogFile()
    if not h then return end
    data = data or {}
    data.t = os.date('!%Y-%m-%dT%H:%M:%SZ')
    data.kind = kind
    local ok, line = pcall(json.encode, data)
    if ok and line then
        h:write(line, '\n')
        h:flush()
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Discord
-- ─────────────────────────────────────────────────────────────────────────────

local queues = {}   -- url -> { items = {}, blockedUntil = ms }

local function cut(s, n)
    return Utils.truncate(tostring(s or ''), n)
end

--- Construit un embed Discord en respectant les limites de l'API.
function Log.embed(opts)
    local e = {
        title = cut(opts.title, 256),
        description = opts.description and cut(opts.description, 3800) or nil,
        color = opts.color or EMBED_COLORS.info,
        fields = {},
        footer = { text = cut(('%s • Rempart v%s'):format(Config.ServerName, Rempart.version), 200) },
        timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    }
    for i, f in ipairs(opts.fields or {}) do
        if i > 20 then break end
        local value = tostring(f.value or '')
        if value == '' then value = '—' end
        e.fields[#e.fields + 1] = { name = cut(f.name, 256), value = cut(value, 1000), inline = f.inline and true or false }
    end
    if opts.image then e.image = { url = opts.image } end
    return e
end

--- Met un message en file d'attente pour un canal ('detections', 'bans', 'admin', 'system').
--- `attachment` = { name = 'capture.jpg', data = <binaire>, mime = 'image/jpeg' } (facultatif)
function Log.discord(channel, embed, content, attachment)
    if not Config.Logs.discord.enabled then return end
    local url = Rempart.webhooks[channel]
    if not url or url == '' then
        url = Rempart.webhooks.system -- repli
        if not url or url == '' then return end
    end
    local q = queues[url]
    if not q then
        q = { items = {}, blockedUntil = 0 }
        queues[url] = q
    end
    if #q.items > 200 then table.remove(q.items, 1) end -- protection mémoire en cas de panne Discord
    q.items[#q.items + 1] = { embed = embed, content = content, attachment = attachment }
end

local function buildMultipart(payload, attachment)
    local boundary = '----Rempart' .. Utils.randomHex(24)
    local parts = {
        '--', boundary, '\r\n',
        'Content-Disposition: form-data; name="payload_json"\r\n',
        'Content-Type: application/json\r\n\r\n',
        json.encode(payload), '\r\n',
        '--', boundary, '\r\n',
        ('Content-Disposition: form-data; name="files[0]"; filename="%s"\r\n'):format(attachment.name),
        ('Content-Type: %s\r\n\r\n'):format(attachment.mime or 'application/octet-stream'),
        attachment.data, '\r\n',
        '--', boundary, '--\r\n',
    }
    return table.concat(parts), 'multipart/form-data; boundary=' .. boundary
end

local function sendBatch(url, q)
    local first = q.items[1]
    local batch, content = {}, nil

    if first.attachment then
        table.remove(q.items, 1)
        batch[1] = first.embed
        content = first.content
    else
        while #q.items > 0 and #batch < 5 and not q.items[1].attachment do
            local item = table.remove(q.items, 1)
            batch[#batch + 1] = item.embed
            if item.content then content = (content and (content .. ' ') or '') .. item.content end
        end
    end

    local payload = {
        username = Config.Logs.discord.username,
        avatar_url = (Config.Logs.discord.avatar ~= '' and Config.Logs.discord.avatar) or nil,
        content = content,
        embeds = batch,
        allowed_mentions = { parse = { 'roles', 'users' } },
    }

    local body, ctype
    if first.attachment then
        payload.attachments = { { id = 0, filename = first.attachment.name } }
        batch[1].image = { url = 'attachment://' .. first.attachment.name }
        body, ctype = buildMultipart(payload, first.attachment)
    else
        body, ctype = json.encode(payload), 'application/json'
    end

    PerformHttpRequest(url, function(status, respBody)
        if status == 429 then
            local retry = 2.0
            local ok, data = pcall(json.decode, respBody or '')
            if ok and type(data) == 'table' and tonumber(data.retry_after) then
                retry = tonumber(data.retry_after)
            end
            q.blockedUntil = Rempart.now() + math.floor(retry * 1000) + 250
            -- remet le lot en tête de file, pièce jointe comprise
            for i = #batch, 1, -1 do
                local attachment = (i == 1) and first.attachment or nil
                if not attachment then batch[i].image = nil end
                table.insert(q.items, 1, { embed = batch[i], content = (i == 1) and content or nil, attachment = attachment })
            end
        elseif status and (status < 200 or status >= 300) and status ~= 0 then
            Log.debug('Webhook Discord : HTTP %s', tostring(status))
        end
    end, 'POST', body, { ['Content-Type'] = ctype })
end

CreateThread(function()
    while true do
        Wait(1300)
        local now = Rempart.now()
        for url, q in pairs(queues) do
            if #q.items > 0 and now >= q.blockedUntil then
                local ok, err = pcall(sendBatch, url, q)
                if not ok then Log.debug('Envoi Discord échoué : %s', tostring(err)) end
            end
        end
    end
end)
