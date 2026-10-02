--[[
    Module : connexion (playerConnecting + deferrals).
    Bans (identifiants + tokens matériels), contournements, pseudo, anti-flood, VPN.
]]

local M = Rempart.module('connection', {})

local lastAttempt = {}   -- license -> ms
local vpnCache = {}      -- ip -> { blocked, ts }

-- Caractères Unicode invisibles (UTF-8) : zero-width, contrôles bidi, BOM…
local INVISIBLE = {
    '\226\128[\139-\143]',  -- U+200B..U+200F
    '\226\128[\168-\174]',  -- U+2028..U+202E
    '\226\129[\160-\164]',  -- U+2060..U+2064
    '\239\187\191',         -- U+FEFF
    '\194\173',             -- U+00AD (trait d'union conditionnel)
}

--- Valide un pseudo. Retourne true, ou false + raison localisée.
function M.checkName(name)
    local cfg = Config.Connection.name
    if not cfg.enabled then return true end
    name = tostring(name or '')
    local len = utf8.len(name) or #name
    local visible = Utils.stripColors(name)
    if (utf8.len(visible) or #visible) < cfg.minLength then return false, L('name_too_short') end
    if len > cfg.maxLength then return false, L('name_too_long') end
    if cfg.blockHtml and name:find('[<>]') then return false, L('name_html') end
    if cfg.blockControl then
        if name:find('%c') then return false, L('name_control') end
        for _, pat in ipairs(INVISIBLE) do
            if name:find(pat) then return false, L('name_control') end
        end
    end
    local lower = name:lower()
    for _, word in ipairs(cfg.blacklist or {}) do
        if lower:find(word:lower(), 1, true) then return false, L('name_blacklist') end
    end
    return true
end

local function isPrivateIp(ip)
    return ip:find('^127%.') or ip:find('^10%.') or ip:find('^192%.168%.') or ip:find('^172%.1[6-9]%.')
        or ip:find('^172%.2%d%.') or ip:find('^172%.3[01]%.') or ip == 'localhost'
end

--- Vérification VPN/proxy via proxycheck.io. cb(blocked:boolean)
local function checkVpn(ip, cb)
    local cached = vpnCache[ip]
    if cached and (os.time() - cached.ts) < 86400 then return cb(cached.blocked) end
    local key = GetConvar('rempart_proxycheck_key', Config.Connection.vpn.apiKey or '')
    local url = ('https://proxycheck.io/v2/%s?vpn=1%s'):format(ip, key ~= '' and ('&key=' .. key) or '')
    local answered = false
    SetTimeout(5000, function()
        if not answered then
            answered = true
            cb(not Config.Connection.vpn.allowOnError)
        end
    end)
    PerformHttpRequest(url, function(status, body)
        if answered then return end
        answered = true
        local ok, data = pcall(json.decode, body or '')
        if status ~= 200 or not ok or type(data) ~= 'table' or type(data[ip]) ~= 'table' then
            return cb(not Config.Connection.vpn.allowOnError)
        end
        local blocked = data[ip].proxy == 'yes'
        vpnCache[ip] = { blocked = blocked, ts = os.time() }
        cb(blocked)
    end, 'GET')
end

local function rejectLog(name, idList, why)
    Rempart.Log.file('reject', { name = name, ids = idList, reason = why })
    Rempart.Log.debug('Connexion refusée : %s (%s)', name, why)
end

AddEventHandler('playerConnecting', function(name, _, deferrals)
    if not Config.Connection.enabled then return end
    local src = source
    deferrals.defer()
    Wait(0)
    deferrals.update(L('connecting'))

    local ids, idList, tokens = Rempart.Players.identify(src)

    -- 1. Identifiants requis
    if Config.Connection.requireLicense and not ids.license then
        rejectLog(name, idList, 'licence absente')
        return deferrals.done(L('no_license'))
    end
    if Config.Connection.requireSteam and not ids.steam then
        return deferrals.done(L('no_steam'))
    end
    if Config.Connection.requireDiscord and not ids.discord then
        return deferrals.done(L('no_discord'))
    end

    -- 2. Bannissements (+ contournement par nouveau compte sur le même PC)
    local ban, how = Rempart.Bans.match(idList, tokens)
    if ban then
        local added = 0
        if Config.Bans.extendOnEvasion then
            added = Rempart.Bans.extend(ban, idList, tokens)
        end
        Rempart.Log.warn('Connexion refusée (banni %s via %s) : %s%s', ban.id, how, name,
            added > 0 and (' — contournement : %d nouveaux identifiants ajoutés au ban'):format(added) or '')
        Rempart.Log.file('banned_connect', { ban = ban.id, name = name, ids = idList, how = how, added = added })
        if added > 0 then
            Rempart.Log.discord('bans', Rempart.Log.embed({
                title = '🚫 ' .. L('ban_evasion'),
                description = ('**%s** a tenté de rejoindre avec un nouveau compte.\nBan `%s` étendu de %d identifiant(s) (correspondance : %s).')
                    :format(Utils.escapeMarkdown(name), ban.id, added, how),
                color = Rempart.Log.colors.critical,
                fields = { { name = 'Identifiants', value = table.concat(idList, '\n') } },
            }))
        end
        Wait(0)
        return deferrals.done(Rempart.Bans.message(ban))
    end

    -- 3. Pseudo
    local okName, why = M.checkName(name)
    if not okName then
        rejectLog(name, idList, 'pseudo : ' .. why)
        return deferrals.done(L('bad_name', why))
    end

    -- 4. Anti-flood de reconnexion
    local lic = ids.license
    if lic and Config.Connection.reconnectCooldown > 0 then
        local now = Rempart.now()
        if lastAttempt[lic] and (now - lastAttempt[lic]) < Config.Connection.reconnectCooldown * 1000 then
            lastAttempt[lic] = now
            return deferrals.done(L('reconnect_flood'))
        end
        lastAttempt[lic] = now
    end

    -- 5. VPN (facultatif, asynchrone)
    local vpn = Config.Connection.vpn
    local ip = ids.ip and ids.ip:sub(4)
    if vpn.enabled and ip and not isPrivateIp(ip) then
        local white = false
        for _, w in ipairs(vpn.whitelist or {}) do
            for _, id in ipairs(idList) do
                if id == w then white = true end
            end
        end
        if not white then
            local p = promise.new()
            checkVpn(ip, function(blocked) p:resolve(blocked) end)
            if Citizen.Await(p) then
                rejectLog(name, idList, 'VPN')
                return deferrals.done(L('vpn_blocked'))
            end
        end
    end

    deferrals.done()
end)

-- Nettoyage de l'anti-flood
CreateThread(function()
    while true do
        Wait(120000)
        local limit = Rempart.now() - 120000
        for lic, t in pairs(lastAttempt) do
            if t < limit then lastAttempt[lic] = nil end
        end
    end
end)
