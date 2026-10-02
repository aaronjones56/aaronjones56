fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'rempart'
author 'Rempart'
description 'Rempart — anti-cheat serveur-autoritaire pour FiveM (OneSync)'
version '1.1.0'

-- Partagé (client + serveur) : SHA-256/HMAC et utilitaires.
shared_scripts {
    'shared/sha256.lua',
    'shared/utils.lua',
}

-- Serveur uniquement : la configuration et les listes ne sont JAMAIS envoyées aux clients.
server_scripts {
    'config.lua',
    'locales/*.lua',
    'lists/*.lua',
    'server/core/catalog.lua',
    'server/core/bootstrap.lua',
    'server/core/log.lua',
    'server/core/storage.lua',
    'server/core/players.lua',
    'server/core/perms.lua',
    'server/core/bans.lua',
    'server/core/screenshot.lua',
    'server/core/files.lua',
    'server/core/punish.lua',
    'server/core/channel.lua',
    'server/core/reports.lua',
    'server/modules/connection.lua',
    'server/modules/entities.lua',
    'server/modules/explosions.lua',
    'server/modules/weapons.lua',
    'server/modules/combat.lua',
    'server/modules/effects.lua',
    'server/modules/tasks.lua',
    'server/modules/movement.lua',
    'server/modules/playerstate.lua',
    'server/modules/vehicles.lua',
    'server/modules/events.lua',
    'server/modules/audit.lua',
    'server/modules/scanner.lua',
    'server/core/commands.lua',
    'server/core/api.lua',
    'server/main.lua',
}

client_scripts {
    'client/main.lua',
    'client/modules/*.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
    -- Bouclier à inclure dans vos autres ressources :  shared_script '@rempart/shield.lua'
    'shield.lua',
}
