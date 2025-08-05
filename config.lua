Config = {}

Config.JoinZone = {
    coords = vector3(-243.63, -2029.09, 28.95),
    radius = 3.0,
    markerType = 1,
    markerColor = { r = 255, g = 100, b = 100, a = 150 },
    text = '~g~[E]~s~ Paintball Lobby'
}

Config.NPC = {
    enabled = true,
    coords = vec4(-243.63, -2029.09, 28.95, 226.02),
    -- NPC ped model. The default here is s_m_y_blackops_01 which represents a
    -- SWAT/Black Ops soldier. You can change this to any valid ped model.
    model = 's_m_y_blackops_01',
    -- The distance within which the ox_target eye will appear for the NPC.
    targetDistance = 2.0
}

Config.Arena = {
    redTeamSpawns = {
        vector3(85.42, -1972.32, 20.78),
        vector3(89.85, -1966.49, 20.75),
        vector3(121.22, -1926.86, 20.99)
    },
    blueTeamSpawns = {
        vector3(40.5, -1923.71, 21.67),
        vector3(79.79, -1894.01, 22.21),
        vector3(46.77, -1917.43, 21.68)
    },
    -- The centre point of the arena; used when drawing markers or
    -- calculating distances. Not strictly necessary but can be useful.
    centre = vector3(84.34, -1923.09, 20.84)
}

Config.GameSettings = {
    killLimit = 20,
    timeLimit = 600,    -- 10 minutes
    respawnDelay = 5,   -- seconds
    joinCooldown = 10   -- seconds to prevent spamming join
}

Config.Rewards = {
    -- Individual reward toggles - set to false to disable specific reward types
    KillRewardEnabled = true,        -- Enable/disable kill rewards
    CompletionBonusEnabled = false,   -- Enable/disable match completion bonus
    WinnerBonusEnabled = false,       -- Enable/disable winner bonus

    -- Money reward per kill: {min, max} - players get a random amount between these values
    KillReward = {400, 600}, -- Min: 400, Max: 600 per kill

    -- Match completion bonus: {min, max} - given to all players when match ends
    CompletionBonus = {1000, 2000}, -- Min: 1000, Max: 2000 for completing a match

    -- Winner bonus: {min, max} - additional bonus for winning team members
    WinnerBonus = {3000, 5000} -- Min: 3000, Max: 5000 extra for winning team
}

-- Police/Dispatch Settings
Config.DisablePoliceAlerts = {
    Enabled = false,                 -- DISABLED: Prevents serialization errors with emergency alerts
    DisableDispatch = true,          -- Disable ps-dispatch alerts
    DisableMDTAlerts = true,         -- Disable MDT alerts
    DisableGunshots = true,          -- Disable gunshot alerts
    DisableDeathAlerts = true,       -- Disable death/injury alerts
    DisableOfficerDown = true,       -- Disable officer down alerts
    DisableEMSAlerts = true,         -- Disable EMS/ambulance alerts
    DisableAllEmergencyAlerts = true, -- Disable all emergency service alerts
}

-- Weapon System Settings
Config.WeaponSystem = {
    UseServerWeapons = false,         -- Try to get weapons from server items first
    FallbackToConfig = true,         -- Use config weapons if server weapons not found
    FilterWeaponTypes = true,        -- Only include actual weapons (not melee/throwables)
    DefaultAmmo = 2000,              -- Default ammo amount for server weapons
}

Config.Weapons = {
    {
        label = 'Pistol',
        hash = 'WEAPON_PISTOL',
        ammo = 2000
    },
    {
        label = 'Pistol Mk II',
        hash = 'WEAPON_PISTOL_MK2',
        ammo = 2000
    },
    {
        label = 'AP Pistol',
        hash = 'WEAPON_APPISTOL',
        ammo = 2000
    },
    {
        label = 'SMG',
        hash = 'WEAPON_SMG',
        ammo = 2000
    },
    {
        label = 'MINIGUN',
        hash = 'WEAPON_MINIGUN',
        ammo = 5000
    }
}

-- Maximum number of players allowed per match. Teams will be split as
-- evenly as possible. If too many players join the lobby the extra
-- players will wait until the next round.
Config.MaxPlayers = 12