-- Analyse statique de Rempart : `luacheck .`
-- Les natives FiveM autorisées sont générées depuis la base officielle (tests/natives/*.txt) :
-- toute native mal orthographiée ou inexistante est signalée.

std = 'lua54'
max_line_length = 160
codes = true

local function load_list(path)
    local list = {}
    local f = io.open(path, 'r')
    if f then
        for line in f:lines() do
            if line ~= '' then list[#list + 1] = line end
        end
        f:close()
    end
    return list
end

local function concat(...)
    local out = {}
    for _, t in ipairs({ ... }) do
        for k, v in pairs(t) do
            if type(k) == 'number' then out[#out + 1] = v else out[k] = v end
        end
    end
    return out
end

-- luacheck compare les globs de `files` au chemin ABSOLU : les crochets du dossier de
-- catégorie « [rempart] » y seraient lus comme une classe de caractères. tools/check.sh
-- copie donc les ressources dans un dossier temporaire sans crochets avant l'analyse.
local function natives(side)
    return load_list('natives/' .. side .. '.txt')
end
local server_natives = natives('server')
local client_natives = natives('client')

-- Fonctions fournies par le runtime Lua de FiveM (scheduler.lua)
local runtime_shared = {
    'Citizen', 'CreateThread', 'Wait', 'SetTimeout', 'ClearTimeout', 'AddEventHandler', 'RemoveEventHandler',
    'RegisterNetEvent', 'TriggerEvent', 'exports', 'json', 'msgpack', 'vector2', 'vector3', 'vector4',
    'vec2', 'vec3', 'vec4', 'quat', 'promise', 'source', 'Entity', 'Player', 'GlobalState',
}
local runtime_server = {
    'TriggerClientEvent', 'TriggerLatentClientEvent', 'RegisterServerEvent', 'GetPlayers', 'GetPlayerIdentifiers',
    'GetPlayerTokens', 'PerformHttpRequest', 'PerformHttpRequestAwait', 'RconPrint', 'GetPlayerEP',
}
local runtime_client = {
    'TriggerServerEvent', 'TriggerLatentServerEvent', 'RegisterNUICallback', 'RegisterNuiCallback',
    'SendNUIMessage', 'LocalPlayer',
}

-- Extensions du sandbox FiveM
local fivem_std = {
    os = { fields = { 'nanotime', 'microtime', 'deltatime', 'rdtsc', 'rdtscp' } },
    io = { fields = { 'readdir' } },
}

local project_globals = { 'Rempart', 'Config', 'Lists', 'Locales', 'Catalog', 'L', 'Sha256', 'Utils' }

files['rempart/shared/*.lua'] = {
    globals = { 'Sha256', 'Utils' },
}

files['rempart/config.lua'] = { globals = { 'Config' }, read_globals = { 'vector3' } }
files['rempart/locales/*.lua'] = { globals = { 'Locales' } }
files['rempart/lists/*.lua'] = { globals = { 'Lists' } }

files['rempart/server/**/*.lua'] = {
    globals = concat(project_globals, { 'source' }),
    read_globals = concat(server_natives, runtime_shared, runtime_server, fivem_std),
}
files['rempart/server/*.lua'] = files['rempart/server/**/*.lua']

files['rempart/client/**/*.lua'] = {
    globals = { 'RMP' },
    read_globals = concat(client_natives, runtime_shared, runtime_client, { 'Utils', 'Sha256' }),
}

-- Le shield redéfinit volontairement des fonctions globales de la ressource hôte.
files['rempart/shield.lua'] = {
    globals = {
        '__rempart_shield', 'AddEventHandler', 'RegisterNetEvent', 'RegisterServerEvent', 'SetEntityCoords',
        'FreezeEntityPosition', 'SetPlayerInvincible', 'GiveWeaponToPed',
    },
    read_globals = concat(client_natives, server_natives, runtime_shared, runtime_server, runtime_client),
    ignore = { '121' }, -- redéfinition volontaire de fonctions globales de la ressource hôte
}

files['rempart_sensor/*.lua'] = {
    read_globals = concat(server_natives, runtime_shared, runtime_server, { 'RegisterResourceAsEventHandler' }),
}

files['rempart/fxmanifest.lua'] = { allow_defined_top = true, globals = { 'fx_version', 'game', 'lua54',
    'name', 'author', 'description', 'version', 'shared_scripts', 'server_scripts', 'client_scripts', 'ui_page', 'files' } }
files['rempart_sensor/fxmanifest.lua'] = { allow_defined_top = true, globals = { 'fx_version', 'game',
    'lua54', 'name', 'author', 'description', 'version', 'server_only', 'server_script' } }

files['.luacheckrc'] = { allow_defined_top = true }
