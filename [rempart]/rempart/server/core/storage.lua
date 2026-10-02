--[[
    Rempart — persistance.

    Bans : KVP (base clé/valeur intégrée à FXServer, aucune dépendance) ou oxmysql
    (table partagée : plusieurs serveurs peuvent partager la même liste de bans).
    Données apprises (points de téléportation, pièges désarmés…) : toujours en KVP.
]]

local Storage = {}
Rempart.Storage = Storage

local BAN_PREFIX = 'rmp:ban:'

-- ─────────────────────────────────────────────────────────────────────────────
-- KV générique (JSON en KVP)
-- ─────────────────────────────────────────────────────────────────────────────

function Storage.get(key, default)
    local raw = GetResourceKvpString('rmp:' .. key)
    if not raw or raw == '' then return default end
    local ok, value = pcall(json.decode, raw)
    if ok and value ~= nil then return value end
    return default
end

function Storage.set(key, value)
    local ok, raw = pcall(json.encode, value)
    if ok and raw then
        SetResourceKvp('rmp:' .. key, raw)
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Backend KVP pour les bans
-- ─────────────────────────────────────────────────────────────────────────────

local kvp = {}

function kvp.init(cb) cb(true) end

function kvp.loadAll(cb)
    local list = {}
    local handle = StartFindKvp(BAN_PREFIX)
    if handle and handle ~= -1 then
        while true do
            local key = FindKvp(handle)
            if not key then break end
            local raw = GetResourceKvpString(key)
            if raw then
                local ok, ban = pcall(json.decode, raw)
                if ok and type(ban) == 'table' and ban.id then
                    list[#list + 1] = ban
                end
            end
        end
        EndFindKvp(handle)
    end
    cb(list)
end

function kvp.save(ban)
    SetResourceKvp(BAN_PREFIX .. ban.id, json.encode(ban))
end

function kvp.delete(id)
    DeleteResourceKvp(BAN_PREFIX .. id)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Backend oxmysql
-- ─────────────────────────────────────────────────────────────────────────────

local mysql = {}
local TABLE = (Config.Bans.oxmysqlTable or 'rempart_bans'):gsub('[^%w_]', '')

local function q(sql, params, cb)
    exports.oxmysql:query(sql, params or {}, function(result)
        if cb then cb(result) end
    end)
end

function mysql.init(cb)
    if GetResourceState('oxmysql') ~= 'started' then
        Rempart.Log.warn('oxmysql n\'est pas démarré : repli sur le stockage KVP.')
        cb(false)
        return
    end
    q(('CREATE TABLE IF NOT EXISTS `%s` (`id` VARCHAR(32) NOT NULL PRIMARY KEY, `data` LONGTEXT NOT NULL, `updated_at` BIGINT NOT NULL)'):format(TABLE),
        {}, function(result)
            cb(result ~= nil)
        end)
end

function mysql.loadAll(cb)
    q(('SELECT `data` FROM `%s`'):format(TABLE), {}, function(rows)
        local list = {}
        for _, row in ipairs(rows or {}) do
            local ok, ban = pcall(json.decode, row.data)
            if ok and type(ban) == 'table' and ban.id then list[#list + 1] = ban end
        end
        cb(list)
    end)
end

function mysql.save(ban)
    q(('INSERT INTO `%s` (`id`, `data`, `updated_at`) VALUES (?, ?, ?) '
        .. 'ON DUPLICATE KEY UPDATE `data` = VALUES(`data`), `updated_at` = VALUES(`updated_at`)'):format(TABLE),
        { ban.id, json.encode(ban), os.time() })
end

function mysql.delete(id)
    q(('DELETE FROM `%s` WHERE `id` = ?'):format(TABLE), { id })
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Sélection du backend
-- ─────────────────────────────────────────────────────────────────────────────

Storage.bans = kvp
Storage.backend = 'kvp'

--- Initialise le backend configuré (repli automatique sur KVP).
function Storage.init(cb)
    if Config.Bans.storage == 'oxmysql' then
        mysql.init(function(ok)
            if ok then
                Storage.bans, Storage.backend = mysql, 'oxmysql'
            end
            cb()
        end)
    else
        cb()
    end
end
