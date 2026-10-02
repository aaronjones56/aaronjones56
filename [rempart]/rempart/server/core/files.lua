--[[
    Rempart — lecture des fichiers de scripts des ressources (lecture seule).

    Le sandbox FiveM autorise la LECTURE des autres ressources (LoadResourceFile,
    io.readdir) mais interdit l'écriture : Rempart ne modifie jamais vos ressources.
]]

local Files = {}
Rempart.Files = Files

local SCRIPT_KEYS = {
    server = { 'server_script', 'shared_script' },
    client = { 'client_script', 'shared_script' },
    all = { 'server_script', 'client_script', 'shared_script' },
}

local function globToPattern(seg)
    local p = seg:gsub('[%^%$%(%)%%%.%[%]%+%-]', '%%%0'):gsub('%*', '[^/]*'):gsub('%?', '[^/]')
    return '^' .. p .. '$'
end

--- Liste le contenu d'un dossier (nil si io.readdir indisponible).
local function readdir(path)
    if not io.readdir then return nil end
    local ok, dir = pcall(io.readdir, path)
    if not ok or not dir then return nil end
    local out = {}
    for name in dir:lines() do
        if name ~= '.' and name ~= '..' then out[#out + 1] = name end
    end
    pcall(dir.close, dir)
    return out
end

local function isDir(path)
    return readdir(path) ~= nil
end

--- Développe un motif glob relatif à une ressource.
local function expand(res, pattern, out)
    local base = GetResourcePath(res)
    if not base or base == '' then return end
    local segs = Utils.split(pattern, '/')

    local function walk(dirRel, i)
        if i > #segs then return end
        local seg = segs[i]
        local dirAbs = dirRel == '' and base or (base .. '/' .. dirRel)
        if seg == '**' then
            walk(dirRel, i + 1) -- zéro dossier
            for _, name in ipairs(readdir(dirAbs) or {}) do
                local rel = dirRel == '' and name or (dirRel .. '/' .. name)
                if isDir(base .. '/' .. rel) then walk(rel, i) end
            end
            return
        end
        if not seg:find('[%*%?]') then
            local rel = dirRel == '' and seg or (dirRel .. '/' .. seg)
            if i == #segs then out[#out + 1] = rel else walk(rel, i + 1) end
            return
        end
        local pat = globToPattern(seg)
        for _, name in ipairs(readdir(dirAbs) or {}) do
            if name:match(pat) then
                local rel = dirRel == '' and name or (dirRel .. '/' .. name)
                if i == #segs then
                    if not isDir(base .. '/' .. rel) then out[#out + 1] = rel end
                else
                    walk(rel, i + 1)
                end
            end
        end
    end

    walk('', 1)
end

--- Fichiers de scripts d'une ressource. side = 'server' | 'client' | 'all'
--- Retourne une liste de { res = <ressource du fichier>, path = <chemin relatif>, owner = <ressource déclarante> }.
function Files.scripts(res, side)
    local out, seen = {}, {}
    for _, key in ipairs(SCRIPT_KEYS[side or 'all']) do
        local n = GetNumResourceMetadata(res, key) or 0
        for i = 0, n - 1 do
            local entry = GetResourceMetadata(res, key, i)
            if type(entry) == 'string' and entry ~= '' then
                local targetRes, path = res, entry
                local other, rest = entry:match('^@([^/]+)/(.+)$')
                if other then targetRes, path = other, rest end
                local paths = {}
                if path:find('[%*%?]') then expand(targetRes, path, paths) else paths[1] = path end
                for _, p in ipairs(paths) do
                    local id = targetRes .. '/' .. p
                    if not seen[id] then
                        seen[id] = true
                        out[#out + 1] = { res = targetRes, path = p, owner = res }
                    end
                end
            end
        end
    end
    return out
end

--- La ressource inclut-elle le shield (« @<anti-cheat>/shield.lua » dans son manifeste) ?
function Files.hasShield(res)
    local target = '@' .. Rempart.res .. '/shield.lua'
    for _, key in ipairs(SCRIPT_KEYS.all) do
        for i = 0, (GetNumResourceMetadata(res, key) or 0) - 1 do
            if GetResourceMetadata(res, key, i) == target then return true end
        end
    end
    return false
end

--- Le shield est-il le tout premier script chargé par la ressource ?
function Files.shieldFirst(res)
    local target = '@' .. Rempart.res .. '/shield.lua'
    if GetResourceMetadata(res, 'shared_script', 0) == target then return true end
    -- sans shared_script, il doit ouvrir la liste des scripts client
    return (GetNumResourceMetadata(res, 'shared_script') or 0) == 0
        and GetResourceMetadata(res, 'client_script', 0) == target
end

--- Toutes les ressources connues du serveur (démarrées ou non).
function Files.resources(startedOnly)
    local list = {}
    for i = 0, GetNumResources() - 1 do
        local name = GetResourceByFindIndex(i)
        if name and (not startedOnly or GetResourceState(name) == 'started') then
            list[#list + 1] = name
        end
    end
    return list
end

--- Contenu d'un fichier (nil si absent). `escrowed` = true si chiffré par l'Asset Escrow.
function Files.read(res, path)
    local ok, content = pcall(LoadResourceFile, res, path)
    if not ok or type(content) ~= 'string' then return nil end
    local escrowed = content:sub(1, 4) == 'FXAP'
    return content, escrowed
end

--- Liste récursive de tous les fichiers .lua/.js d'une ressource (scanner).
function Files.allCode(res)
    local base = GetResourcePath(res)
    local out = {}
    if not base or base == '' or not io.readdir then return out end
    local function walk(rel, depth)
        if depth > 8 or #out > 2000 then return end
        local abs = rel == '' and base or (base .. '/' .. rel)
        for _, name in ipairs(readdir(abs) or {}) do
            local childRel = rel == '' and name or (rel .. '/' .. name)
            if name ~= 'node_modules' and name ~= '.git' and isDir(base .. '/' .. childRel) then
                walk(childRel, depth + 1)
            elseif name:match('%.lua$') or name:match('%.js$') then
                out[#out + 1] = childRel
            end
        end
    end
    walk('', 0)
    return out
end
