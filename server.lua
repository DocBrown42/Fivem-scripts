-- server.lua
-- Server side logic for the paintball mini‑game. This script handles
-- lobby creation, player management, score tracking and match timing.

local QBCore = exports['qb-core']:GetCoreObject()

-- Internal lobby state. When a lobby is active this table will hold
-- host, players and settings. The host is the player who created the
-- lobby and is the only one allowed to start the game. Each entry in
-- players contains kills, deaths and team assignment.
local Lobby = {
    host = nil,
    players = {}, -- [src] = {id = src, team = 1 or 2, kills = 0, deaths = 0}
    settings = {},
    started = false,
    startTime = 0,
    bucket = nil -- routing bucket id for the current match
}

-- Utility: broadcast a client event to all players currently in the
-- lobby. Accepts event name and variadic arguments. This ensures only
-- participants receive updates.
local function broadcast(eventName, ...)
    for playerId, _ in pairs(Lobby.players) do
        TriggerClientEvent(eventName, playerId, ...)
    end
end

-- Utility: count players per team and return which team has fewer
-- members. This helps balance the teams when players join.
local function getBalancedTeam()
    local counts = { [1] = 0, [2] = 0 }
    for _, info in pairs(Lobby.players) do
        counts[info.team] = counts[info.team] + 1
    end
    if counts[1] <= counts[2] then
        return 1
    else
        return 2
    end
end

-- Utility: compile scoreboard data for sending to clients. Returns a
-- table with kills per team and optionally individual scores. For
-- simplicity we only send team scores here; client can compute totals.
local function getScoreboard()
    local teamKills = { [1] = 0, [2] = 0 }
    local individual = {}

    for src, info in pairs(Lobby.players) do
        local team = tonumber(info.team)  -- force it to be a number
        local kills = tonumber(info.kills) or 0
        local deaths = tonumber(info.deaths) or 0



        -- Only count if team is 1 or 2
        if team == 1 or team == 2 then
            teamKills[team] = (teamKills[team] or 0) + kills
        end

        table.insert(individual, {
            id = src,
            name = GetPlayerName(src) or 'Unknown',
            team = team,
            kills = kills,
            deaths = deaths
        })
    end


    return { teamKills = teamKills, individual = individual }
end


-- Ends the current game. Sends a message to all players, resets
-- lobby/player state and optionally announces the winning team. The
-- reason parameter describes why the match ended (kill limit/time).
local function endGame(reason)
    if not Lobby.started then return end
    Lobby.started = false
    local scoreboard = getScoreboard()
    local winningTeam
    -- Determine winner by kill limit or by comparing kills when time
    -- expires.
    if reason == 'kills' then
        -- The team that just reached kill limit is the winner. We find
        -- which team has the most kills.
        if scoreboard.teamKills[1] > scoreboard.teamKills[2] then
            winningTeam = 1
        else
            winningTeam = 2
        end
    elseif reason == 'time' then
        if scoreboard.teamKills[1] > scoreboard.teamKills[2] then
            winningTeam = 1
        elseif scoreboard.teamKills[2] > scoreboard.teamKills[1] then
            winningTeam = 2
        else
            winningTeam = 0 -- tie
        end
    else
        winningTeam = 0
    end
    broadcast('qb-paintball:endGame', winningTeam, scoreboard)

    -- Give match completion and winner bonuses if individually enabled
    for playerId, info in pairs(Lobby.players) do
        local totalReward = 0
        local rewardComponents = {}

        -- Completion bonus for all players
        if Config.Rewards.CompletionBonusEnabled and Config.Rewards.CompletionBonus then
            local minBonus = Config.Rewards.CompletionBonus[1] or 1000
            local maxBonus = Config.Rewards.CompletionBonus[2] or 2000
            local completionReward = math.random(minBonus, maxBonus)
            totalReward = totalReward + completionReward
            table.insert(rewardComponents, "Completion bonus")
        end

        -- Winner bonus for winning team members
        if Config.Rewards.WinnerBonusEnabled and winningTeam > 0 and info.team == winningTeam and Config.Rewards.WinnerBonus then
            local minWinBonus = Config.Rewards.WinnerBonus[1] or 3000
            local maxWinBonus = Config.Rewards.WinnerBonus[2] or 5000
            local winnerReward = math.random(minWinBonus, maxWinBonus)
            totalReward = totalReward + winnerReward
            table.insert(rewardComponents, "Winner bonus")
        end

        -- Give the total reward
        if totalReward > 0 then
            local success = exports.ox_inventory:AddItem(playerId, 'money', totalReward)
            if success then
                local message = string.format('Match bonus: $%d', totalReward)
                if #rewardComponents > 0 then
                    message = message .. ' (' .. table.concat(rewardComponents, " + ") .. ')'
                end
                TriggerClientEvent('QBCore:Notify', playerId, message, 'success')

            end
        end
    end

    -- Reset lobby state but keep players in lobby so they can start a
    -- new game quickly. Kills and deaths are reset.
    for _, info in pairs(Lobby.players) do
        info.kills = 0
        info.deaths = 0
    end
    Lobby.started = false
    Lobby.startTime = 0
    -- Reset players back to the default routing bucket (0) and clear
    -- the match bucket. This returns all participants to the main
    -- world after the match concludes.
    if Lobby.bucket then
        for id, _ in pairs(Lobby.players) do
            SetPlayerRoutingBucket(id, 0)
            -- Re-enable police alerts for this player if they were disabled
            if Config.DisablePoliceAlerts.Enabled then
                TriggerClientEvent('qb-paintball:disablePoliceAlerts', id, false)
            end
        end
        Lobby.bucket = nil
    end
end

-- Event: client requests to create a lobby. Only one lobby may exist at
-- any time. The host can set the kill/time limits. If the lobby
-- already exists this event returns false to the requesting client.
RegisterNetEvent('qb-paintball:createLobby', function(settings)
    local src = source
    if Lobby.host then
        TriggerClientEvent('qb-paintball:lobbyCreated', src, false, 'A lobby already exists.')
        return
    end
    Lobby.host = src
    Lobby.players[src] = { id = src, team = 1, kills = 0, deaths = 0 }
    Lobby.settings = {
        killLimit = tonumber(settings.killLimit) or Config.GameSettings.killLimit,
        timeLimit = tonumber(settings.timeLimit) or Config.GameSettings.timeLimit,
        -- Weapon selection index; default to 1 if not provided. Clients send
        -- `weaponIndex` from the NUI when creating the lobby. We ensure the
        -- value is within bounds of Config.Weapons.
        weaponIndex = (tonumber(settings.weaponIndex) and Config.Weapons[tonumber(settings.weaponIndex)] and tonumber(settings.weaponIndex)) or 1
    }
    Lobby.started = false
    Lobby.startTime = 0
    Lobby.bucket = nil
    TriggerClientEvent('qb-paintball:lobbyCreated', src, true)
    broadcast('qb-paintball:refreshLobby', Lobby.host, Lobby.settings, getScoreboard())
end)

-- Event: client requests to join an existing lobby. Players will be
-- assigned to the team with fewer members. If the game has already
-- started new players are refused until the next round. Returns whether
-- the join succeeded along with the assigned team.
RegisterNetEvent('qb-paintball:joinLobby', function()
    local src = source
    if not Lobby.host then
        TriggerClientEvent('qb-paintball:joinedLobby', src, false, 'No lobby to join.')
        return
    end
    if Lobby.started then
        TriggerClientEvent('qb-paintball:joinedLobby', src, false, 'Game already in progress. Please wait.')
        return
    end
    -- Prevent duplicate join
    if Lobby.players[src] then
        TriggerClientEvent('qb-paintball:joinedLobby', src, false, 'You are already in the lobby.')
        return
    end
    -- Capacity check
    local count = 0
    for _ in pairs(Lobby.players) do count = count + 1 end
    if count >= Config.MaxPlayers then
        TriggerClientEvent('qb-paintball:joinedLobby', src, false, 'Lobby is full.')
        return
    end
    local team = getBalancedTeam()
    Lobby.players[src] = { id = src, team = team, kills = 0, deaths = 0 }
    TriggerClientEvent('qb-paintball:joinedLobby', src, true, team)
    broadcast('qb-paintball:refreshLobby', Lobby.host, Lobby.settings, getScoreboard())
end)

-- Event: host requests to start the game. Once started no more
-- participants may join until the match ends. All players are sent
-- spawn coordinates and game settings. The server also begins a timer
-- thread if a time limit is set.
RegisterNetEvent('qb-paintball:startGame', function()
    local src = source
    print(string.format("🎮 Start game request from player %s (host: %s)", src, Lobby.host))
    if src ~= Lobby.host then
        print("❌ Player is not the host")
        return
    end
    if Lobby.started then
        print("❌ Game already started")
        return
    end
    -- Require at least 2 players to start the game. If there are fewer
    -- than two participants, notify the host and do not begin.
    local playerCount = 0
    for _ in pairs(Lobby.players) do
        playerCount = playerCount + 1
    end
    if playerCount < 2 then
        TriggerClientEvent('qb-paintball:lobbyCreated', src, false, 'At least 2 players are required to start a match.')
        return
    end
    Lobby.started = true
    Lobby.startTime = os.time()
    -- Create a routing bucket for this match if it doesn't exist. The
    -- bucket ID is derived from the current game timer and host ID to
    -- reduce the chance of collision. Using routing buckets isolates
    -- the paintball arena from the main world so players do not
    -- interfere with other gameplay. When the match ends the bucket
    -- will be cleared and all players returned to the default world.
    if not Lobby.bucket then
        Lobby.bucket = GetGameTimer() + src
    end
    -- Build spawn assignments. We cycle through spawn lists to avoid
    -- running out of positions when there are more players than spawn
    -- points. Each team has its own spawn table.
    local redSpawns = Config.Arena.redTeamSpawns
    local blueSpawns = Config.Arena.blueTeamSpawns
    local redIdx, blueIdx = 1, 1
    for id, info in pairs(Lobby.players) do
        local spawn
        if info.team == 1 then
            spawn = redSpawns[redIdx]
            redIdx = redIdx + 1
            if redIdx > #redSpawns then redIdx = 1 end
        else
            spawn = blueSpawns[blueIdx]
            blueIdx = blueIdx + 1
            if blueIdx > #blueSpawns then blueIdx = 1 end
        end
        -- Send per‑player spawn location and team assignment. The
        -- additional table includes weapon settings and match rules so
        -- clients know how to configure themselves.
        TriggerClientEvent('qb-paintball:startGame', id, {
            spawn = spawn,
            team = info.team,
            killLimit = Lobby.settings.killLimit,
            timeLimit = Lobby.settings.timeLimit,
            weapon = Config.Weapons[Lobby.settings.weaponIndex] or Config.Weapons[1]
        })
        -- Assign the player to the match routing bucket
        SetPlayerRoutingBucket(id, Lobby.bucket)

        -- Disable police alerts for this player if enabled
        if Config.DisablePoliceAlerts.Enabled then
            TriggerClientEvent('qb-paintball:disablePoliceAlerts', id, true)
        end
    end
    -- Send initial scoreboard to all players
    broadcast('qb-paintball:updateScoreboard', getScoreboard())
    -- If a time limit is configured start a timer thread to count
    -- down. We avoid long loops when no time limit is set.
    if Lobby.settings.timeLimit and Lobby.settings.timeLimit > 0 then
        Citizen.CreateThread(function()
            while Lobby.started do
                Citizen.Wait(1000)
                local elapsed = os.time() - Lobby.startTime
                local remaining = Lobby.settings.timeLimit - elapsed
                -- Send remaining time to clients
                broadcast('qb-paintball:updateTimer', remaining)
                if remaining <= 0 then
                    endGame('time')
                    break
                end
            end
        end)
    end
end)

-- Event: host updates lobby settings (kill limit, time limit, weapon index).
-- This allows the host to change game settings without recreating the
-- lobby. Only the host can call this event. After updating the
-- settings we broadcast a refresh to all players so the lobby menu
-- displays the updated values.
RegisterNetEvent('qb-paintball:updateLobby', function(settings)
    local src = source
    if not Lobby.host or src ~= Lobby.host then
        return
    end
    if not Lobby.settings then return end
    -- Update kill limit and time limit if provided
    if settings then
        if settings.killLimit then
            local kl = tonumber(settings.killLimit)
            if kl and kl > 0 then
                Lobby.settings.killLimit = kl
            end
        end
        if settings.timeLimit then
            local tl = tonumber(settings.timeLimit)
            if tl and tl >= 0 then
                Lobby.settings.timeLimit = tl
            end
        end
        if settings.weaponIndex then
            local idx = tonumber(settings.weaponIndex)
            if idx and Config.Weapons[idx] then
                Lobby.settings.weaponIndex = idx
            end
        end
    end
    -- Notify clients of updated settings
    broadcast('qb-paintball:refreshLobby', Lobby.host, Lobby.settings, getScoreboard())
end)

-- Event: a player died. The client sends the ID of the killer if
-- available (may be nil if death was environmental). We increment
-- deaths and kills accordingly. After updating scores we check for
-- kill limit. If the limit is reached the game ends.
RegisterNetEvent('qb-paintball:playerDied', function(killerId)
    local src = source
    if not Lobby.started then return end

    local victim = Lobby.players[src]
    if not victim then return end



    -- Increment victim death count
    victim.deaths = (victim.deaths or 0) + 1

    -- Increment killer's kill count
    if killerId and Lobby.players[killerId] then
        local killer = Lobby.players[killerId]
        killer.kills = (killer.kills or 0) + 1


        -- Give kill reward if enabled
        if Config.Rewards.KillRewardEnabled and Config.Rewards.KillReward then
            local minReward = Config.Rewards.KillReward[1] or 400
            local maxReward = Config.Rewards.KillReward[2] or 600
            local rewardAmount = math.random(minReward, maxReward)

            -- Give money item using ox_inventory
            local success = exports.ox_inventory:AddItem(killerId, 'money', rewardAmount)
            if success then
                TriggerClientEvent('QBCore:Notify', killerId,
                    string.format('Kill reward: $%d', rewardAmount), 'success')

            end
        end
    end

    -- ✅ Get updated scoreboard AFTER updating stats
    local scoreboard = getScoreboard()

    -- ✅ Check kill limit using updated scoreboard
    if killerId and Lobby.players[killerId] then
        local killer = Lobby.players[killerId]
        local t = killer.team
        if t and scoreboard.teamKills[t] >= Lobby.settings.killLimit then
            endGame('kills')
            return
        end
    end

    -- ✅ Send updated scoreboard to all players
    broadcast('qb-paintball:updateScoreboard', scoreboard)
end)



-- Event: a player requests to change their team. The desiredTeam
-- parameter should be 1 or 2. The server checks that a lobby exists
-- and the game has not started. It also ensures the team sizes
-- remain balanced (difference of at most 1). If successful the
-- player's team assignment is updated and the lobby is refreshed for
-- all participants.
RegisterNetEvent('qb-paintball:setTeam', function(desiredTeam)
    local src = source
    desiredTeam = tonumber(desiredTeam)

    if not desiredTeam or (desiredTeam ~= 1 and desiredTeam ~= 2) then return end
    if not Lobby.host then
        TriggerClientEvent('qb-paintball:joinedLobby', src, false, 'No lobby to join.')
        return
    end
    if Lobby.started then
        TriggerClientEvent('qb-paintball:joinedLobby', src, false, 'Game already in progress.')
        return
    end
    if not Lobby.players[src] then return end

    -- Count current team sizes
    local counts = { [1] = 0, [2] = 0 }
    for _, info in pairs(Lobby.players) do
        local team = tonumber(info.team)
        if team == 1 or team == 2 then
            counts[team] = counts[team] + 1
        end
    end

    -- Allow team switch even if already on a team
    local currentTeam = tonumber(Lobby.players[src].team)
    if currentTeam == desiredTeam then
        -- Already on the desired team
        TriggerClientEvent('qb-paintball:joinTeamResult', src, false, 'You are already on that team.')
        return
    end

    -- Allow switch as long as teams won’t be more than 1 off
    local other = desiredTeam == 1 and 2 or 1
    if counts[desiredTeam] + 1 > counts[other] + (currentTeam == other and 1 or 0) + 1 then
        TriggerClientEvent('qb-paintball:joinTeamResult', src, false, 'That team is currently full.')
        return
    end

    -- ✅ Assign new team
    Lobby.players[src].team = desiredTeam

    -- 🔁 Refresh lobby view for everyone
    broadcast('qb-paintball:refreshLobby', Lobby.host, Lobby.settings, getScoreboard())
    TriggerClientEvent('qb-paintball:joinTeamResult', src, true)
end)


-- Event: a player leaves the lobby voluntarily. Removes them from the
-- lobby. If they are the host, the lobby is disbanded and all players
-- are notified. If the game is running it is terminated.
RegisterNetEvent('qb-paintball:leaveLobby', function()
    local src = source
    if not Lobby.players[src] then return end
    -- If the leaving player is the host, end any game and clear lobby
    if src == Lobby.host then
        endGame('host left')
        for id, _ in pairs(Lobby.players) do
            TriggerClientEvent('qb-paintball:lobbyClosed', id)
        end
        Lobby.host = nil
        Lobby.players = {}
        Lobby.settings = {}
        return
    end
    -- Remove player from lobby
    Lobby.players[src] = nil
    TriggerClientEvent('qb-paintball:lobbyLeft', src)
    broadcast('qb-paintball:refreshLobby', Lobby.host, Lobby.settings, getScoreboard())
end)

-- Remove players from lobby if they disconnect. Also handle host
-- departure similar to leaveLobby.
AddEventHandler('playerDropped', function(reason)
    local src = source
    if Lobby.players[src] then
        if src == Lobby.host then
            -- Host left; disband lobby
            endGame('host left')
            for id, _ in pairs(Lobby.players) do
                if id ~= src then
                    TriggerClientEvent('qb-paintball:lobbyClosed', id)
                end
            end
            Lobby.host = nil
            Lobby.players = {}
            Lobby.settings = {}
        else
            -- Remove leaving player and refresh scoreboard
            Lobby.players[src] = nil
            broadcast('qb-paintball:refreshLobby', Lobby.host, Lobby.settings, getScoreboard())
        end
    end
end)



-- Export function to check if a player is in a paintball match
-- Other scripts can use this to prevent emergency alerts
local function isPlayerInPaintball(playerId)
    return Lobby.players[playerId] ~= nil and Lobby.started
end

exports('isPlayerInPaintball', isPlayerInPaintball)

-- Export function to check if emergency alerts should be disabled for a player
local function shouldDisableEmergencyAlerts(playerId)
    if not Config.DisablePoliceAlerts.Enabled then return false end
    return isPlayerInPaintball(playerId)
end

exports('shouldDisableEmergencyAlerts', shouldDisableEmergencyAlerts)

-- Cache for weapons list to avoid recalculating
local cachedWeapons = nil

-- Function to get available weapons from server or config
local function getAvailableWeapons()
    -- Return cached weapons if available
    if cachedWeapons then
        return cachedWeapons
    end

    local weapons = {}

    -- Try to get weapons from QBCore shared items first if enabled
    if Config.WeaponSystem.UseServerWeapons and QBCore and QBCore.Shared and QBCore.Shared.Items then
        for itemName, itemData in pairs(QBCore.Shared.Items) do
            if itemData.type == 'weapon' and itemData.name then
                -- Filter out melee weapons and throwables if configured
                local isValidWeapon = true
                if Config.WeaponSystem.FilterWeaponTypes then
                    local weaponName = string.upper(itemData.name)
                    -- Skip melee weapons, throwables, and other non-gun weapons
                    if weaponName:find('KNIFE') or weaponName:find('BAT') or
                       weaponName:find('HAMMER') or weaponName:find('CROWBAR') or
                       weaponName:find('GRENADE') or weaponName:find('MOLOTOV') or
                       weaponName:find('STUNGUN') or weaponName:find('NIGHTSTICK') or
                       weaponName:find('FLASHLIGHT') or weaponName:find('BOTTLE') then
                        isValidWeapon = false
                    end
                end

                if isValidWeapon then
                    table.insert(weapons, {
                        label = itemData.label or itemName,
                        hash = itemData.name,
                        ammo = Config.WeaponSystem.DefaultAmmo
                    })
                end
            end
        end
    end

    -- If no weapons found from server and fallback is enabled, use config weapons
    if #weapons == 0 and Config.WeaponSystem.FallbackToConfig then
        weapons = Config.Weapons
    end

    -- Sort weapons alphabetically by label
    table.sort(weapons, function(a, b)
        return (a.label or ''):lower() < (b.label or ''):lower()
    end)

    -- Cache the result
    cachedWeapons = weapons
    return weapons
end

-- Export function to get weapons list
exports('getAvailableWeapons', getAvailableWeapons)

-- Handle client request for weapons list
RegisterNetEvent('qb-paintball:requestWeapons', function()
    local src = source
    local weapons = getAvailableWeapons()
    TriggerClientEvent('qb-paintball:receiveWeapons', src, weapons)
end)

-- Note: Emergency alert blocking has been disabled to prevent serialization errors
-- If you need to block alerts, consider using client-side blocking instead
-- or implementing a different approach that doesn't interfere with event data