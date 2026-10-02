--[[
    Module : scanner de backdoors (lecture seule, au démarrage + `rmp scan`).

    Cibles : Cipher Panel et loaders distants, portes dérobées réseau (code reçu d'un
    client puis exécuté), vol de secrets du server.cfg, commandes système, API sensibles
    cachées dans des chaînes obfusquées. Rien n'est modifié : un rapport est produit.
]]

local M = Rempart.module('scanner', {})
Rempart.Scanner = M

M.findings = {}
M.lastRun = nil

-- Faux positifs connus des ressources système officielles.
local KNOWN_SAFE = {
    yarn = { js_child_process = true },
    webpack = { js_child_process = true },
}

local SEVERITY_ORDER = { critical = 4, high = 3, medium = 2, low = 1 }
local SEVERITY_ICON = { critical = '🟥', high = '🟧', medium = '🟨', low = '⬜' }

local function lineOf(content, pos)
    local _, n = content:sub(1, pos):gsub('\n', '')
    return n + 1
end

--- Séquences contiguës d'un motif unitaire (les motifs Lua n'ont pas de quantificateur de groupe).
local function runs(content, unit, minUnits)
    local out, init = {}, 1
    while true do
        local s, e = content:find(unit, init)
        if not s then break end
        local stop, units = e, 1
        while true do
            local s2, e2 = content:find(unit, stop + 1)
            if s2 ~= stop + 1 then break end
            stop, units = e2, units + 1
        end
        if units >= minUnits then out[#out + 1] = { pos = s, run = content:sub(s, stop) } end
        init = stop + 1
    end
    return out
end

--- Extrait et décode les chaînes obfusquées. Retourne une liste de { text, pos }.
function M.decodeObfuscated(content)
    local out = {}
    -- \x50\x65\x72…
    for _, r in ipairs(runs(content, '\\x%x%x', 4)) do
        local text = r.run:gsub('\\x(%x%x)', function(h) return string.char(tonumber(h, 16)) end)
        out[#out + 1] = { text = text, pos = r.pos }
    end
    -- \080\101\114…
    for _, r in ipairs(runs(content, '\\%d%d?%d?', 4)) do
        local okDecode = true
        local text = r.run:gsub('\\(%d%d?%d?)', function(d)
            local n = tonumber(d)
            if n > 255 then
                okDecode = false
                return ''
            end
            return string.char(n)
        end)
        if okDecode then out[#out + 1] = { text = text, pos = r.pos } end
    end
    -- string.char(80, 101, 114, …)
    for pos, list in content:gmatch('()string%.char%s*%(([%d%s,]+)%)') do
        local chars, okDecode = {}, true
        for num in list:gmatch('%d+') do
            local n = tonumber(num)
            if n > 255 then okDecode = false break end
            chars[#chars + 1] = string.char(n)
        end
        if okDecode and #chars >= 4 then out[#out + 1] = { text = table.concat(chars), pos = pos } end
    end
    return out
end

--- Callback dont un paramètre est passé à un "puits" d'exécution (load/eval…).
local function scanCallback(content, sig, hit)
    local init = 1
    while true do
        local s, e = content:find(sig.a, init)
        if not s then break end
        init = e + 1
        local window = content:sub(e + 1, e + 400)
        local hs, he, params = window:find('function%s*%(([^%)]*)%)')
        if not hs then hs, he, params = window:find('%(([^%)]*)%)%s*=>') end
        if hs then
            local body = window:sub(he + 1) .. content:sub(e + 401, e + 1000)
            for param in params:gmatch('[%a_][%w_]*') do
                for _, sink in ipairs(sig.sinks) do
                    if body:find(sink .. '%s*%(%s*' .. param .. '%f[^%w_]') then
                        hit(s)
                        return
                    end
                end
            end
        end
    end
end

local function scanFile(res, path, content, minified)
    local found = {}
    local function report(sig, pos, extra)
        if KNOWN_SAFE[res] and KNOWN_SAFE[res][sig.id] then return end
        found[#found + 1] = {
            res = res, file = path, line = lineOf(content, pos), id = sig.id,
            severity = sig.severity, desc = sig.desc .. (extra and (' — ' .. extra) or ''),
        }
    end

    for _, dom in ipairs(Lists.BackdoorDomains) do
        local pos = content:find(dom)
        if pos then
            report({ id = 'known_c2', severity = 'critical', desc = 'Domaine de panneau de backdoor connu' }, pos, (dom:gsub('%%', '')))
        end
    end

    local decoded = (not minified) and M.decodeObfuscated(content) or {}
    for _, sig in ipairs(Lists.BackdoorSignatures) do
        if sig.kind == 'callback' then
            scanCallback(content, sig, function(pos) report(sig, pos) end)
        elseif sig.kind == 'near' then
            local init = 1
            while true do
                local s, e = content:find(sig.a, init)
                if not s then break end
                init = e + 1
                local around = content:sub(math.max(1, s - sig.within), e + sig.within)
                if around:find(sig.b) then
                    report(sig, s)
                    break
                end
            end
        elseif sig.kind == 'pattern' and not minified then
            local pos = content:find(sig.a)
            if pos then report(sig, pos) end
        elseif sig.kind == 'decoded' then
            for _, d in ipairs(decoded) do
                if d.text:find(sig.a) then
                    report(sig, d.pos, ('« %s »'):format(Utils.truncate((d.text:gsub('%c', ' ')), 40)))
                    break
                end
            end
        end
    end
    return found
end

--- Analyse toutes les ressources. cb(findings) en fin d'analyse.
function M.run(cb)
    CreateThread(function()
        local started = os.clock()
        local findings, files = {}, 0
        local ignore = Utils.set(Config.Scanner.ignoreResources)
        ignore[Rempart.res] = true
        ignore['rempart_sensor'] = true
        for _, res in ipairs(Rempart.Files.resources(false)) do
            if not ignore[res] then
                for _, path in ipairs(Rempart.Files.allCode(res)) do
                    local content, escrowed = Rempart.Files.read(res, path)
                    if content and not escrowed and #content <= Config.Scanner.maxFileSize then
                        files = files + 1
                        local lines = select(2, content:gsub('\n', '')) + 1
                        local minified = (#content / lines) > 500
                        for _, f in ipairs(scanFile(res, path, content, minified)) do
                            findings[#findings + 1] = f
                        end
                    end
                    if files % 10 == 0 then Wait(0) end
                end
            end
        end
        table.sort(findings, function(a, b)
            if a.severity ~= b.severity then return SEVERITY_ORDER[a.severity] > SEVERITY_ORDER[b.severity] end
            return a.res < b.res
        end)
        M.findings, M.lastRun = findings, os.time()
        M.print(findings, files, os.clock() - started)
        if cb then cb(findings) end
    end)
end

function M.print(findings, files, elapsed)
    local counts = { critical = 0, high = 0, medium = 0, low = 0 }
    for _, f in ipairs(findings) do counts[f.severity] = counts[f.severity] + 1 end
    local color = (counts.critical > 0 and '^1') or (counts.high > 0 and '^3') or '^2'
    print(('^5[Rempart]^7 ════════ Scanner de backdoors : %s%d alerte(s)^7 (%d fichiers, %.1f s) ════════')
        :format(color, #findings, files or 0, elapsed or 0))
    local lines = {}
    for i, f in ipairs(findings) do
        if i <= 40 then
            print(('  %s %s/%s:%d^7 [%s] %s'):format(
                f.severity == 'critical' and '^1' or (f.severity == 'high' and '^3' or '^8'),
                f.res, f.file, f.line, f.id, f.desc))
        end
        if #lines < 15 then
            lines[#lines + 1] = ('%s `%s/%s:%d` — %s'):format(SEVERITY_ICON[f.severity], f.res, f.file, f.line, f.desc)
        end
    end
    if counts.critical > 0 then
        print('^1  ⚠ Alerte critique : isolez la ressource, réinstallez-la depuis une source officielle et changez'
            .. ' votre clé de licence, mot de passe RCON, accès base de données et txAdmin.^7')
    end
    if #findings > 0 then
        Rempart.Log.discord('system', Rempart.Log.embed({
            title = ('🦠 Scanner de backdoors : %d alerte(s) (%d critique(s))'):format(#findings, counts.critical),
            description = table.concat(lines, '\n'),
            color = counts.critical > 0 and Rempart.Log.colors.critical or Rempart.Log.colors.warn,
        }))
    end
end

function M.init()
    if Config.Scanner.onStart then
        SetTimeout(8000, function() M.run() end)
    end
end
