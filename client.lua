-- client.lua
-- Client side logic for the paintball mini‑game. Handles interaction with
-- the game world (markers and prompts), opens the NUI lobby, manages
-- player death/respawn, weapon handling and scoreboard updates.

local QBCore = exports['qb-core']:GetCoreObject()

-- State variables
local inLobby = false
local inGame = false
local isHost = false
local team = 0
local spawnCoords = nil
local killLimit = 0
local timeLimit = 0
local scoreboard = { teamKills = { [1] = 0, [2] = 0 }, individual = {} }
local remainingTime = 0
local lastDeathTime = 0
local joinCooldown = 0
local savedPosition = nil
local savedHeading = nil
local savedWeapon = nil
local savedWeaponAmmo = 0

-- Stores the currently selected paintball weapon for this match. This
-- is populated when the match begins (in qb-paintball:startGame) and
-- used when respawning so players receive the same weapon after death.
-- The table contains the fields { hash, ammo }. Tints are no longer
-- applied by default to avoid conflicts with ox_inventory. If you
-- decide to use tints again, add a `tint` property here.
local currentWeapon = nil

-- Dynamic weapons system
local availableWeapons = nil
local weaponsLoaded = false

-- Load weapons list when resource starts
CreateThread(function()
    -- Wait for QBCore to be ready
    while not QBCore do
        Wait(100)
    end

    -- Request weapons from server
    TriggerServerEvent('qb-paintball:requestWeapons')
end)

-- Handle weapons list response from server
RegisterNetEvent('qb-paintball:receiveWeapons', function(weapons)
    availableWeapons = weapons or Config.Weapons
    weaponsLoaded = true
end)

-- Helper to convert weapon identifiers into numeric hashes. Config.Weapons
-- entries may provide either a backtick literal (number) or a string
-- weapon name (e.g. 'WEAPON_PISTOL'). This function ensures we always
-- use a numeric hash when giving weapons.
local function toWeaponHash(val)
    if not val then return nil end
    if type(val) == 'number' then
        return val
    end
    return GetHashKey(val)
end

-- Store the latest lobby settings received from the server. This is used to
-- reopen the lobby menu with the correct values after closing it. The
-- variable is updated whenever we receive a refreshLobby event or create/join
-- a lobby. When reopening the menu we fall back to this if no
-- lobbySettings argument is provided.
local lastLobbySettings = nil

-- If using an NPC instead of a marker, we define an event to open the lobby
-- menu when the player interacts with the NPC via ox_target. This event is
-- triggered from the ox_target interaction defined later. It simply opens
-- the lobby menu in the same way as pressing E in the marker would.
RegisterNetEvent('qb-paintball:npcInteract', function(data)
    -- Only allow opening if we are not currently in a match. This prevents
    -- players from reopening the lobby menu mid‑match. Use our current
    -- isHost flag when opening so hosts see the proper controls. We pass
    -- through lastLobbySettings so the menu repopulates with the current
    -- lobby information when reopening after closing via the X button.
    if not inGame then
        openLobbyMenu(isHost, nil, scoreboard)
    end
end)

-- Helper: draw 3D text. Creates floating text at a world position. The
-- text scales with distance and displays for one frame; call every
-- tick when near the marker.
local function Draw3DText(x, y, z, text, scale)
    local onScreen, _x, _y = World3dToScreen2d(x, y, z)
    local px, py, pz = table.unpack(GetGameplayCamCoords())
    local dist = #(vector3(px, py, pz) - vector3(x, y, z))
    local s = (scale or 0.35) / dist
    local fov = (1 / GetGameplayCamFov()) * 100
    s = s * fov
    if onScreen then
        SetTextScale(0.0 * s, 0.35 * s)
        SetTextFont(4)
        SetTextProportional(true)
        SetTextColour(255, 255, 255, 215)
        SetTextDropshadow(0, 0, 0, 0, 255)
        SetTextEdge(2, 0, 0, 0, 150)
        SetTextDropShadow()
        SetTextOutline()
        SetTextEntry('STRING')
        AddTextComponentString(text)
        DrawText(_x, _y)
    end
end

-- Save the player's current position, heading and primary weapon. We
-- restore this information when the match ends. We only save the
-- currently equipped weapon to reduce complexity.
local function savePlayerState()
    local ped = PlayerPedId()
    savedPosition = GetEntityCoords(ped)
    savedHeading = GetEntityHeading(ped)
    local weaponHash = GetSelectedPedWeapon(ped)
    if weaponHash and weaponHash ~= 0 then
        savedWeapon = weaponHash
        savedWeaponAmmo = GetAmmoInPedWeapon(ped, weaponHash)
    else
        savedWeapon = nil
        savedWeaponAmmo = 0
    end
end

-- Restore the player's weapon if we saved one previously. Note that
-- restoring the position is handled when the match ends; we teleport
-- players back to their original location on the server side.
local function restorePlayerWeapon()
    local ped = PlayerPedId()
    if savedWeapon then
        GiveWeaponToPed(ped, savedWeapon, savedWeaponAmmo or 0, false, false)
        SetCurrentPedWeapon(ped, savedWeapon, true)
    end
    savedWeapon = nil
    savedWeaponAmmo = 0
end

-- Resurrect the local player at the stored spawn coordinates. Called
-- when the client detects they have died during a match. After
-- respawning we re‑equip the paintball weapon.
local function respawnPlayer()
    local ped = PlayerPedId()
    if not spawnCoords then return end
    -- Fade out and in for a smoother respawn
    DoScreenFadeOut(300)
    while not IsScreenFadedOut() do Citizen.Wait(50) end
    -- Choose a new spawn point from the team's spawn list. This
    -- prevents players from always respawning at the exact same
    -- location during a match. We determine the appropriate spawn
    -- list based on the player's current team assignment and pick a
    -- random entry. If for some reason the team is not set, fall
    -- back to the original spawnCoords.
    do
        local spawns
        if team and type(team) == 'number' and team > 0 then
            if team == 1 then
                spawns = Config.Arena.redTeamSpawns
            else
                spawns = Config.Arena.blueTeamSpawns
            end
        end
        if spawns and #spawns > 0 then
            local idx = math.random(#spawns)
            local newSpawn = spawns[idx]
            spawnCoords = newSpawn
        end
    end
    NetworkResurrectLocalPlayer(spawnCoords.x, spawnCoords.y, spawnCoords.z, 0.0, true, false)
    ClearPedTasksImmediately(ped)
    -- Allow a brief moment for the resurrection to take effect, then
    -- fully restore the player's health and clear any bleedout state. We
    -- set health to the ped's maximum and also trigger the hospital
    -- revive event used by qb‑ambulancejob to reset death state.
    Citizen.Wait(100)
    local maxHealth = GetEntityMaxHealth(ped)
    SetEntityHealth(ped, maxHealth)
    -- Trigger the standard revive event provided by qb‑ambulancejob if
    -- available. This ensures any death flags are cleared so the player
    -- is no longer in last stand or bleedout. If the event doesn't exist
    -- on your server, it will simply do nothing.
    TriggerEvent('hospital:client:Revive')
    -- Additionally trigger qbx_medical's playerRevived event if present. In
    -- the qbx framework, this event handles resetting the player's death
    -- state and restoring their health. If the event does not exist it
    -- will be ignored.
    TriggerEvent('qbx_medical:client:playerRevived')
    -- As a fallback, explicitly reset death and laststand status on the
    -- server. These events are provided by qb‑ambulancejob and will
    -- ensure the server clears any dead/laststand flags if the
    -- client‑side revive event does not. If these events are not
    -- available on your server they will be ignored.
    TriggerServerEvent('hospital:server:SetDeathStatus', false)
    TriggerServerEvent('hospital:server:SetLaststandStatus', false)
    RemoveAllPedWeapons(ped, true)
    -- Give paintball weapon again. Before equipping the weapon we
    -- temporarily enable weapon usage for this player via
    -- LocalPlayer.state.canUseWeapons. Without this the ox_inventory
    -- restrictions may prevent the weapon from being given. After
    -- giving the weapon we leave this state set to true for the
    -- duration of the match. When the match ends the state will be
    -- reset in qb‑paintball:endGame.
    if currentWeapon then
        local weaponHash = toWeaponHash(currentWeapon.hash)
        -- Allow giving weapons outside inventory
        LocalPlayer.state.canUseWeapons = true
        exports.ox_inventory:weaponWheel(true)
        GiveWeaponToPed(ped, weaponHash, currentWeapon.ammo or 0, false, true)
        SetCurrentPedWeapon(ped, weaponHash, true)
    end
    DoScreenFadeIn(300)
end

-- Opens the paintball lobby menu by focusing the NUI and sending
-- relevant state. The NUI uses messages to update its internal state.
local function openLobbyMenu(host, lobbySettings, currentScoreboard)
    -- Check if weapons are loaded
    if not weaponsLoaded then
        QBCore.Functions.Notify('Loading weapons list...', 'primary', 2000)

        -- Wait for weapons to load with timeout
        local attempts = 0
        while not weaponsLoaded and attempts < 50 do -- 5 second timeout
            Wait(100)
            attempts = attempts + 1
        end

        if not weaponsLoaded then
            QBCore.Functions.Notify('Failed to load weapons, using defaults', 'error')
            availableWeapons = Config.Weapons
            weaponsLoaded = true
        end
    end

    SetNuiFocus(true, true)
    -- Send available weapons to the NUI so hosts can pick which gun
    -- will be used for the match. We send the weapons list (either from
    -- server or config fallback), which includes label, hash and ammo.
    SendNUIMessage({
        action = 'openMenu',
        isHost = host,
        -- Use the provided lobbySettings if available; otherwise fall back
        -- to our last known lobby settings. This allows the menu to
        -- repopulate with the current lobby details when reopening.
        lobby = lobbySettings or lastLobbySettings or nil,
        scoreboard = currentScoreboard or nil,
        team = team,
        weapons = availableWeapons or Config.Weapons
    })
    inLobby = true
end



-- Closes the lobby menu. The scoreboard overlay remains if we are
-- in‑game.
local function closeLobbyMenu()
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'closeMenu' })
end

-- NUI callback: request to create a lobby. We pass kill/time limits
-- back to the server. The callback receives a table containing
-- killLimit and timeLimit.
RegisterNUICallback('createLobby', function(data, cb)
    TriggerServerEvent('qb-paintball:createLobby', {
        killLimit = data.killLimit,
        timeLimit = data.timeLimit,
        weaponIndex = data.weaponIndex
    })
    cb({})
end)

-- NUI callback: request to join an existing lobby.
RegisterNUICallback('joinLobby', function(data, cb)
    TriggerServerEvent('qb-paintball:joinLobby')
    cb({})
end)

-- NUI callback: request to leave the lobby. If we are host this
-- disbands the lobby; otherwise we simply leave.
RegisterNUICallback('leaveLobby', function(data, cb)
    TriggerServerEvent('qb-paintball:leaveLobby')
    cb({})
end)

-- NUI callback: host requests to start the match.
RegisterNUICallback('startGame', function(data, cb)
    print("🎮 Start game button clicked - sending to server")
    TriggerServerEvent('qb-paintball:startGame')
    cb({})
end)

-- NUI callback: host updates lobby settings (kill limit, time limit, weapon index).
-- This event is used to modify an existing lobby's configuration without
-- recreating it. Only the host can call this.
RegisterNUICallback('updateLobby', function(data, cb)
    TriggerServerEvent('qb-paintball:updateLobby', {
        killLimit = data.killLimit,
        timeLimit = data.timeLimit,
        weaponIndex = data.weaponIndex
    })
    cb({})
end)

-- NUI callback: close menu (e.g. click close button). This does not
-- remove the player from the lobby.
RegisterNUICallback('closeMenu', function(data, cb)
    closeLobbyMenu()
    cb({})
end)

-- NUI callback: setTeam
-- Allows the player to request a change to their team before the match
-- has begun. The `data.team` value should be 1 or 2. The server
-- validates the request, updates the player's team assignment if
-- possible and broadcasts a lobby refresh. There is no response
-- payload for this callback.
RegisterNUICallback('setTeam', function(data, cb)
    if data and data.team then
        TriggerServerEvent('qb-paintball:setTeam', data.team)
    end
    cb({})
end)

-- Receive lobby creation response. If success is false a reason may be
-- provided. On success we mark the local player as host and open the
-- menu.
RegisterNetEvent('qb-paintball:lobbyCreated', function(success, msg)
    if success then
        isHost = true
        -- Save initial lobby settings so we can reopen the menu later
        lastLobbySettings = Config.GameSettings
        openLobbyMenu(true, Config.GameSettings, scoreboard)
    else
        QBCore.Functions.Notify(msg or 'Unable to create lobby.', 'error')
    end
end)

-- Receive join response. If success is false show an error; otherwise
-- record team assignment and open the menu if not already open.
RegisterNetEvent('qb-paintball:joinedLobby', function(success, t)
    if not success then
        QBCore.Functions.Notify(t or 'Unable to join lobby.', 'error')
        return
    end
    team = t
    isHost = false
    -- Save initial lobby settings on join
    lastLobbySettings = Config.GameSettings
    openLobbyMenu(false, Config.GameSettings, scoreboard)
end)

-- Refresh lobby information. Contains host id, lobby settings and
-- scoreboard for display in the lobby menu. We update our local
-- scoreboard but do not change any state flags.
RegisterNetEvent('qb-paintball:refreshLobby', function(hostId, settings, score)
    scoreboard = score or scoreboard
    -- Update our cached lobby settings whenever the server tells us about
    -- changes. This ensures we can reopen the menu with up‑to‑date values.
    lastLobbySettings = settings

    -- Update our local team assignment from the scoreboard data
    if scoreboard and scoreboard.individual then
        local myServerId = GetPlayerServerId(PlayerId())
        for _, player in ipairs(scoreboard.individual) do
            if player.id == myServerId then
                team = player.team
                break
            end
        end
    end

    SendNUIMessage({
        action = 'refreshLobby',
        host = hostId,
        lobby = settings,
        scoreboard = scoreboard,
        team = team
    })
end)

-- Notifies us that the lobby has been closed (e.g. host left). We
-- close the menu and reset flags.
RegisterNetEvent('qb-paintball:lobbyClosed', function()
    if inLobby then
        QBCore.Functions.Notify('Paintball lobby closed.', 'error')
        closeLobbyMenu()
    end
    isHost = false
    team = 0
    inLobby = false
    -- Clear cached lobby settings since the lobby no longer exists
    lastLobbySettings = nil
    scoreboard = { teamKills = { [1] = 0, [2] = 0 }, individual = {} }
end)

-- Notifies us that we have left the lobby (not host). Resets state.
RegisterNetEvent('qb-paintball:lobbyLeft', function()
    QBCore.Functions.Notify('You left the paintball lobby.', 'primary')
    closeLobbyMenu()
    -- Reset local flags and cached settings when leaving the lobby
    isHost = false
    inLobby = false
    team = 0
    lastLobbySettings = nil
    scoreboard = { teamKills = { [1] = 0, [2] = 0 }, individual = {} }
end)

-- Handle team switch result. Provides feedback when team switching succeeds or fails.
RegisterNetEvent('qb-paintball:joinTeamResult', function(success, message)
    if success then
        QBCore.Functions.Notify('Team switched successfully!', 'success')
    else
        QBCore.Functions.Notify(message or 'Failed to switch teams.', 'error')
    end
end)

-- Handle police alert disabling/enabling during matches
RegisterNetEvent('qb-paintball:disablePoliceAlerts', function(disable)
    if not Config.DisablePoliceAlerts.Enabled then return end

    local playerId = PlayerId()
    local ped = PlayerPedId()

    if disable then
        -- Disable police alerts during match
        if Config.DisablePoliceAlerts.DisableDispatch then
            -- Disable ps-dispatch alerts by setting player state
            LocalPlayer.state.disableDispatch = true
        end

        if Config.DisablePoliceAlerts.DisableGunshots then
            -- Disable gunshot detection
            LocalPlayer.state.disableGunshots = true
        end

        if Config.DisablePoliceAlerts.DisableDeathAlerts then
            -- Disable death/injury alerts
            LocalPlayer.state.disableDeathAlerts = true
        end

        if Config.DisablePoliceAlerts.DisableMDTAlerts then
            -- Disable MDT alerts
            LocalPlayer.state.disableMDTAlerts = true
        end

        if Config.DisablePoliceAlerts.DisableOfficerDown then
            -- Disable officer down alerts
            LocalPlayer.state.disableOfficerDown = true
            LocalPlayer.state.isInPaintball = true
        end

        if Config.DisablePoliceAlerts.DisableEMSAlerts then
            -- Disable EMS/ambulance alerts
            LocalPlayer.state.disableEMSAlerts = true
        end

        if Config.DisablePoliceAlerts.DisableAllEmergencyAlerts then
            -- Disable all emergency alerts
            LocalPlayer.state.disableAllEmergencyAlerts = true
            LocalPlayer.state.paintballMatch = true
        end

        -- Set player as invincible to prevent actual death/injury
        SetEntityInvincible(ped, true)

    else
        -- Re-enable police alerts after match
        if Config.DisablePoliceAlerts.DisableDispatch then
            -- Re-enable ps-dispatch alerts by clearing player state
            LocalPlayer.state.disableDispatch = false
        end

        if Config.DisablePoliceAlerts.DisableGunshots then
            -- Re-enable gunshot detection
            LocalPlayer.state.disableGunshots = false
        end

        if Config.DisablePoliceAlerts.DisableDeathAlerts then
            -- Re-enable death/injury alerts
            LocalPlayer.state.disableDeathAlerts = false
        end

        if Config.DisablePoliceAlerts.DisableMDTAlerts then
            -- Re-enable MDT alerts
            LocalPlayer.state.disableMDTAlerts = false
        end

        if Config.DisablePoliceAlerts.DisableOfficerDown then
            -- Re-enable officer down alerts
            LocalPlayer.state.disableOfficerDown = false
            LocalPlayer.state.isInPaintball = false
        end

        if Config.DisablePoliceAlerts.DisableEMSAlerts then
            -- Re-enable EMS/ambulance alerts
            LocalPlayer.state.disableEMSAlerts = false
        end

        if Config.DisablePoliceAlerts.DisableAllEmergencyAlerts then
            -- Re-enable all emergency alerts
            LocalPlayer.state.disableAllEmergencyAlerts = false
            LocalPlayer.state.paintballMatch = false
        end

        -- Remove invincibility
        SetEntityInvincible(ped, false)
    end
end)

-- Block ps-dispatch calls during paintball matches
if Config.DisablePoliceAlerts and Config.DisablePoliceAlerts.Enabled then
    -- Block the specific ps-dispatch officer down event
    AddEventHandler('ps-dispatch:client:officerdown', function()
        if LocalPlayer.state.disableOfficerDown or LocalPlayer.state.paintballMatch then
            CancelEvent()
        end
    end)

    -- Block other common ps-dispatch events
    AddEventHandler('ps-dispatch:client:notify', function(data)
        if LocalPlayer.state.disableDispatch or LocalPlayer.state.paintballMatch then
            CancelEvent()
        end
    end)

    -- Block gunshot alerts
    AddEventHandler('ps-dispatch:client:gsrPositive', function()
        if LocalPlayer.state.disableGunshots or LocalPlayer.state.paintballMatch then
            CancelEvent()
        end
    end)

    -- Block EMS alerts
    AddEventHandler('ps-dispatch:client:emsDown', function()
        if LocalPlayer.state.disableEMSAlerts or LocalPlayer.state.paintballMatch then
            CancelEvent()
        end
    end)


end

-- Start game event from the server. Receives a table with spawn
-- coordinates, team and match rules. We save our current state,
-- teleport to spawn and equip the paintball weapon. A short delay
-- allows players to load into the arena before the match begins.
RegisterNetEvent('qb-paintball:startGame', function(data)
    if not data or not data.spawn then return end
    -- Close the lobby menu automatically if open
    if inLobby then
        closeLobbyMenu()
    end
    inGame = true
    inLobby = false
    team = data.team
    spawnCoords = data.spawn
    killLimit = data.killLimit or Config.GameSettings.killLimit
    timeLimit = data.timeLimit or Config.GameSettings.timeLimit
    scoreboard = { teamKills = { [1] = 0, [2] = 0 }, individual = {} }
    remainingTime = timeLimit
    -- Save and strip weapons
    savePlayerState()
    local ped = PlayerPedId()
    RemoveAllPedWeapons(ped, true)
    -- Teleport to spawn
    DoScreenFadeOut(500)
    while not IsScreenFadedOut() do Citizen.Wait(50) end
    SetEntityCoordsNoOffset(ped, spawnCoords.x, spawnCoords.y, spawnCoords.z, false, false, false)
    SetEntityHeading(ped, 0.0)
    -- Wait a bit to make sure other players are spawned before we start
    Citizen.Wait(1000)
    -- Give paintball weapon. We temporarily enable weapon usage via
    -- LocalPlayer.state.canUseWeapons and enable the weapon wheel so
    -- ox_inventory does not block the weapon. Store the selected
    -- weapon in currentWeapon so we can re‑equip it on respawn.
    if data.weapon then
        local weaponHash = toWeaponHash(data.weapon.hash)
        currentWeapon = {
            hash = weaponHash,
            ammo = data.weapon.ammo or 0
        }
        LocalPlayer.state.canUseWeapons = true
        exports.ox_inventory:weaponWheel(true)
        GiveWeaponToPed(ped, weaponHash, currentWeapon.ammo, false, true)
        SetCurrentPedWeapon(ped, weaponHash, true)
    else
        currentWeapon = nil
    end
    DoScreenFadeIn(500)
    -- Notify
    QBCore.Functions.Notify('Match starting... Get Ready!', 'primary')
    -- Show scoreboard overlay
    local nuiData = {
        action = 'showScoreboard',
        scoreboard = {
            teamKills = {
                red = (scoreboard and scoreboard.teamKills and scoreboard.teamKills[1]) or 0,
                blue = (scoreboard and scoreboard.teamKills and scoreboard.teamKills[2]) or 0
            },
            individual = (scoreboard and scoreboard.individual) or {}
        },
        timer = remainingTime
    }
    SendNUIMessage(nuiData)
end)

-- Update scoreboard event. Stores the new scoreboard and updates the
-- overlay. This event is sent frequently by the server when kills
-- occur.
RegisterNetEvent('qb-paintball:updateScoreboard', function(score)
    scoreboard = score or scoreboard


    -- Ensure proper structure for NUI by explicitly creating the object with string keys
    local nuiData = {
        action = 'updateScoreboard',
        scoreboard = {
            teamKills = {
                red = (scoreboard and scoreboard.teamKills and scoreboard.teamKills[1]) or 0,
                blue = (scoreboard and scoreboard.teamKills and scoreboard.teamKills[2]) or 0
            },
            individual = (scoreboard and scoreboard.individual) or {}
        }
    }



    SendNUIMessage(nuiData)
end)

-- Update remaining timer. Called by the server each second if a time
-- limit is set.
RegisterNetEvent('qb-paintball:updateTimer', function(secondsRemaining)
    remainingTime = secondsRemaining
    SendNUIMessage({ action = 'updateTimer', timer = secondsRemaining})
end)

-- End game event. The match is over. We announce the winning team,
-- remove scoreboard overlay and restore player weapon/state. Players
-- remain at the arena until the host starts another round or they
-- choose to leave.
RegisterNetEvent('qb-paintball:endGame', function(winningTeam, finalScore)
    inGame = false
    SendNUIMessage({ action = 'hideScoreboard' })
    scoreboard = finalScore or scoreboard
    -- Determine message
    local msg
    if winningTeam == 0 then
        msg = 'The match ended in a tie!'
    elseif winningTeam == team then
        msg = 'Your team won the match!'
    else
        msg = 'Your team lost the match.'
    end
    QBCore.Functions.Notify(msg, 'primary')
    -- Restore player's saved weapon. Before restoring, disable paintball
    -- weapon access by resetting weapon controls. This re‑enables
    -- inventory weapons and hides the weapon wheel. Afterwards we call
    -- restorePlayerWeapon() to give back the original weapon.
    LocalPlayer.state.canUseWeapons = nil
    exports.ox_inventory:weaponWheel(false)
    restorePlayerWeapon()
    -- Teleport the player back to the lobby marker after a short delay
    Citizen.CreateThread(function()
        Citizen.Wait(2000)
        local ped = PlayerPedId()
        local pos = Config.JoinZone.coords
        DoScreenFadeOut(500)
        while not IsScreenFadedOut() do Citizen.Wait(50) end
        -- Teleport to the lobby/join zone
        SetEntityCoordsNoOffset(ped, pos.x, pos.y, pos.z, false, false, false)
        SetEntityHeading(ped, 0.0)
        -- match end revive logic fix
        TriggerServerEvent('hospital:server:SetLaststandStatus', false)
        TriggerEvent('qbx_medical:client:playerRevived') -- optional again here
        -- ^ Fix for player dead after match ends
        if IsEntityDead(ped) or GetEntityHealth(ped) <= 0 then
            -- Resurrect at the join zone
            NetworkResurrectLocalPlayer(pos.x, pos.y, pos.z, 0.0, true, false)
            ClearPedTasksImmediately(ped)
            Citizen.Wait(100)
            local maxHealth = GetEntityMaxHealth(ped)
            SetEntityHealth(ped, maxHealth)
            -- Trigger revive events for both qb-ambulancejob and qbx_medical
            TriggerEvent('hospital:client:Revive')
            TriggerEvent('qbx_medical:client:playerRevived')
            TriggerServerEvent('hospital:server:SetDeathStatus', false)
            TriggerServerEvent('hospital:server:SetLaststandStatus', false)
        end
        DoScreenFadeIn(500)
        -- Reset spawnCoords to nil so that the next respawn cycle does
        -- not inadvertently teleport the player back to their team
        -- spawn after the game has ended.
        spawnCoords = nil
    end)
end)

-- Thread: monitors the player's proximity to the lobby marker. When
-- within range it draws a marker and 3D text prompt. Pressing E
-- opens the lobby menu. A cooldown prevents spamming.
-- If NPC lobby is disabled, fall back to marker interaction. When
-- Config.NPC.enabled is false we draw a marker and allow players to
-- press E to open the lobby. Otherwise the NPC handles menu
-- interaction via ox_target.
if not (Config.NPC and Config.NPC.enabled) then
    Citizen.CreateThread(function()
        while true do
            local ped = PlayerPedId()
            local coords = GetEntityCoords(ped)
            local dist = #(coords - Config.JoinZone.coords)
            if dist <= Config.JoinZone.radius then
                -- Draw marker
                DrawMarker(Config.JoinZone.markerType, Config.JoinZone.coords.x, Config.JoinZone.coords.y, Config.JoinZone.coords.z - 1.0,
                           0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0,
                           Config.JoinZone.markerColor.r, Config.JoinZone.markerColor.g, Config.JoinZone.markerColor.b, Config.JoinZone.markerColor.a,
                           false, true, 2, nil, nil, false)
                Draw3DText(Config.JoinZone.coords.x, Config.JoinZone.coords.y, Config.JoinZone.coords.z + 0.1, Config.JoinZone.text, 0.4)
                -- Check for key press
                if IsControlJustPressed(0, 38) then
                    if joinCooldown <= 0 and not inGame then
                        -- Pass through isHost so that if the player is the host
                        -- they see the host controls when reopening the lobby.
                        openLobbyMenu(isHost, nil, scoreboard)
                        joinCooldown = Config.GameSettings.joinCooldown
                    end
                end
            end
            if joinCooldown > 0 then
                joinCooldown = joinCooldown - 0.02
            end
            Citizen.Wait(10)
        end
    end)
end

-- Spawn the lobby NPC and attach an ox_target interaction. When the player
-- interacts with the NPC the lobby menu will open. This is only done if
-- Config.NPC.enabled is true. The NPC is placed at Config.NPC.coords and
-- uses the model specified in Config.NPC.model. After spawning the
-- ped, we freeze it in place and make it invincible so it remains in
-- the lobby area. The ox_target option triggers the
-- `qb-paintball:npcInteract` client event defined above.
if Config.NPC and Config.NPC.enabled then
    Citizen.CreateThread(function()
        local modelHash = Config.NPC.model
        -- Support string model names by converting to hash
        if type(modelHash) == 'string' then
            modelHash = GetHashKey(modelHash)
        end
        RequestModel(modelHash)
        while not HasModelLoaded(modelHash) do
            Citizen.Wait(50)
        end
        local coords = Config.NPC.coords
        -- Create the NPC ped at the specified location and heading
        local ped = CreatePed(4, modelHash, coords.x, coords.y, coords.z, coords.w, false, true)
        SetEntityHeading(ped, coords.w)
        SetEntityInvincible(ped, true)
        -- Enable collision so the NPC properly stands on the ground instead of
        -- hovering. Disabling collision caused the ped to float above the
        -- ground. Keep it enabled while still freezing the ped's position.
        SetEntityCollision(ped, true, true)
        FreezeEntityPosition(ped, true)
        -- Play a clipboard animation to give the NPC some life. We use
        -- WORLD_HUMAN_CLIPBOARD so the NPC holds a clipboard and
        -- writes on it. If the scenario is unavailable the ped will
        -- simply stand. We also prevent the NPC from reacting to
        -- damage or other events by blocking non‑temporary events.
        if not IsPedUsingAnyScenario(ped) then
            TaskStartScenarioInPlace(ped, 'WORLD_HUMAN_CLIPBOARD', 0, true)
        end
        SetBlockingOfNonTemporaryEvents(ped, true)
        SetPedFleeAttributes(ped, 0, false)
        SetPedCombatAttributes(ped, 17, 1)
        -- Attach ox_target interaction to the NPC. Use the native
        -- addLocalEntity function provided by ox_target. Each entry in
        -- the options array defines a single selectable option. We set
        -- the distance property on the option itself to control how
        -- close players must be for the eye to appear. This avoids
        -- relying on the qtarget compatibility exports which may not be
        -- available on some servers.
        exports['ox_target']:addLocalEntity(ped, {
            {
                name = 'paintball_lobby',
                label = 'Paintball Lobby',
                icon = 'fa-solid fa-flag',
                -- Directly open the lobby menu when selected instead of
                -- triggering an intermediate event. Pass through the
                -- current host flag so that hosts see the correct controls
                -- when reopening the lobby. Only allow opening if we are
                -- not currently in a match.
                onSelect = function(data)
                    if not inGame then
                        openLobbyMenu(isHost, nil, scoreboard)
                    end
                end,
                distance = Config.NPC.targetDistance or 2.0
            }
        })
    end)
end
-- Thread: monitors player death during a match and handles respawn and
-- notifying the server. When the player dies we send the killer's
-- server ID if available. After a respawn delay the player is
-- resurrected at their spawn point and given the paintball weapon.
Citizen.CreateThread(function()
    while true do
        if inGame then
            local ped = PlayerPedId()
            if IsEntityDead(ped) and (GetGameTimer() - lastDeathTime > 1000) then
                lastDeathTime = GetGameTimer()
                -- Find the killer ped and map to server ID if possible
                local killer = GetPedSourceOfDeath(ped)
                local killerId = nil
                if killer and killer ~= ped then
                    if IsPedAPlayer(killer) then
                        killerId = GetPlayerServerId(NetworkGetPlayerIndexFromPed(killer))
                    end
                end
                TriggerServerEvent('qb-paintball:playerDied', killerId)
                -- Wait respawn delay then respawn locally. Only respawn
                -- if the game is still running; if it ended during the
                -- delay (e.g. kill limit reached or time expired),
                -- skip the respawn and rely on the endGame handler to
                -- relocate and revive the player.
                Citizen.Wait(Config.GameSettings.respawnDelay * 1000)
                if inGame then
                    respawnPlayer()
                end
            end
        end
        Citizen.Wait(50)
    end
end)

CreateThread(function()
    local blip = AddBlipForCoord(-243.78, -2029.02, 29.95) -- your location
    SetBlipSprite(blip, 160)         -- Pistol icon
    SetBlipDisplay(blip, 4)          -- Show on main map and minimap
    SetBlipScale(blip, 1.0)          -- Size of the blip
    SetBlipColour(blip, 53)           -- Yellow, you can change this
    SetBlipAsShortRange(blip, true)  -- Only visible when nearby
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentString("PaintBall") -- Name on the map
    EndTextCommandSetBlipName(blip)
end)