local M = {}

M.defaults = {
  debug = false,
  mode = "classic", -- classic | tag

  roundTime = 300,
  hideTime = 60,
  allowSoloTest = false,

  -- seeker selection
  seekerMode = "fixed", -- fixed | ratio
  seekerCount = 1,
  seekerRatio = 0.25,

  -- cooldowns (seconds)
  tauntCooldown = 5,
  flashCooldown = 15,
  tagCooldown = 0.0,
  scanCooldown = 0.1,
  sameTargetCooldown = 1.0,
  cleanupSweepSeconds = 15,
  tempPropSweepSeconds = 15, -- legacy alias
  forceGhostOffOnRestore = true,
  spawnswapRetryCount = 2,
  seekerTabPrevention = false,
  allowNodeGrabInRound = false,
  allowHiderResetInRound = false,

  -- visuals
  seekerFadeDist = 120,
  seekerFilterIntensity = 1.0,
  hiderFadeDist = 120,
  hiderFilterIntensity = 0.35,

  -- join behavior while round is active: lock_next_round | spectator | seeker | hider
  joinPolicy = "lock_next_round",

  -- disguise pipeline: replace (stable) | preload (experimental) | spawnswap (experimental)
  disguiseMode = "replace",

  -- Next-round-only forced prop (nil => random)
  nextRoundForcedProp = nil,

  -- admin ACL (string IDs / exact names)
  -- default OFF for backwards compatibility
  adminAclEnabled = false,
  adminIds = {},
  adminNames = {},

  -- anti-spam hard floors (seconds)
  minEventGapTempProp = 0.05,
  minEventGapTag = 0.05,
  minEventGapTaunt = 0.05,
  minEventGapScan = 0.05,

  -- tag corroboration (anti-spoof)
  requireTagCorroboration = true,
  requireMutualContact = false,
  tagCorroborationWindow = 0.35,

  -- gameplay profile
  currentPreset = "casual", -- casual | ranked | chaos

  -- map-aware profile binding (mapKey -> preset)
  mapProfiles = {
    west_coast_usa = "ranked",
    utah = "casual"
  },

  -- map-aware spawn banks (optional hints; can be used by client scripts/tools)
  -- spawnBanks = {
  --   west_coast_usa = {
  --     seekers = { {x=0,y=0,z=0}, {x=10,y=0,z=0} },
  --     hiders  = { {x=100,y=20,z=0}, {x=120,y=20,z=0} }
  --   }
  -- }
  spawnBanks = {},

  -- prop tier balancing
  propTierMode = "all", -- all | ranked | chaos

  -- economy / perks
  perksEnabled = true,

  -- optional auto-start while idle
  autorunEnabled = false,
  autorunIntervalSeconds = 600,
  autorunMinPlayers = 2, -- starts when connected players > this value

  -- Prop pool (official internal names)
  propPool = {
    "anticut", "barrels", "ball", "barrier", "barrier_plastic", "blockwall", "bollard",
    "caravan", "chair", "cones", "couch", "crowdbarrier", "delineator", "engine_props",
    "flail", "flipramp", "fridge", "gate", "haybale", "kickplate", "logs", "marble_block",
    "mattress", "metal_box", "metal_ramp", "piano", "porta_potty", "rallyflags", "rallysigns",
    "roadsigns", "rock_pile", "rocks", "sawhorse", "shipping_container", "spikestrip",
    "steel_coil", "trampoline", "tirewall", "trafficbarrel", "trashbin", "tube", "tv",
    "wall", "woodcrate", "woodplanks"
  }
}

return M
