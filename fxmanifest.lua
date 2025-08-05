-- fxmanifest.lua
-- Resource manifest for the paintball mini‑game. This resource is built
-- specifically for QBCore (also known as qbox). It defines client and
-- server entry points as well as web UI files that are served to the
-- player. The ui_page directive tells FiveM which HTML file to load
-- when displaying the NUI.

fx_version 'cerulean'
game 'gta5'

lua54 'yes'

author 'DocBrown42'
description 'A paintball mini‑game with a modern lobby and scoreboard NUI for QBCore/qbox'
version '1.0.0'

-- Shared configuration is loaded on both client and server. This makes
-- configuration values available to both sides without duplication.
shared_scripts {
    'config.lua'
}

-- Client script handles user interaction, spawning and UI callbacks.
client_scripts {
    'client.lua'
}

-- Server script tracks game state, manages players and propagates events
-- between clients. If you use a database library such as oxmysql you can
-- add it here, but it is not required for this mini‑game.
server_scripts {
    'server.lua'
}

-- Define the NUI page and include all files the UI requires. When the
-- resource is started these files will be served to the client. You
-- should avoid referencing external resources in your HTML as FiveM
-- blocks cross‑origin requests by default.
ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/script.js'
}