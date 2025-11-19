fx_version 'cerulean'
games { 'gta5' }

author 'Azure(TheStoicBear)'
description 'Fishing minigame (NUI reel spin)'
version '1.0.0'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua'
}

client_scripts {
    'source/fish.lua',
    'source/client.lua',
    'source/anchor.lua'

} 
server_script 'source/server.lua'

ui_page 'html/index.html'

files {
  'html/index.html',
  'html/sfx/*'
}
