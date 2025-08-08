fx_version 'cerulean'
game 'gta5'

name 'qb-player-shop'
author 'Leon'
description 'QBCore NUI shop + courier delivery (solo test mode)'
version '2.2.0'
lua54 'yes'

ui_page 'html/index.html'

files {
    'html/index.html'
}

shared_script 'config.lua'

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    '@qb-core/shared/locale.lua',
    'server.lua'
}

client_scripts {
    '@qb-core/shared/locale.lua',
    'client.lua'
}

dependencies {
    'qb-core'
    -- For icons:
    -- 'qb-inventory'
}
