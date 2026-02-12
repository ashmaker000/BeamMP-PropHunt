local M = {}

M.defaults = {
  debug = false,
  mode = "classic", -- classic | tag

  roundTime = 300,
  hideTime = 60,

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

  -- visuals
  seekerFadeDist = 120,
  seekerFilterIntensity = 1.35,
  hiderFadeDist = 120,
  hiderFilterIntensity = 0.35,

  -- join behavior while round is active: lock_next_round | spectator | seeker | hider
  joinPolicy = "lock_next_round",

  -- disguise pipeline: replace (stable) | preload (experimental) | spawnswap (experimental)
  disguiseMode = "spawnswap",

  -- Next-round-only forced prop (nil => random)
  nextRoundForcedProp = nil,

  -- Prop pool (official internal names)
  propPool = {
    "anticut", "barrels", "ball", "barrier", "barrier_plastic", "blockwall", "bollard",
    "caravan", "chair", "cones", "couch", "crowdbarrier", "delineator", "engine_props",
    "flail", "flipramp", "fridge", "gate", "haybale", "kickplate", "logs", "marble_block",
    "mattress", "metal_box", "metal_ramp", "piano", "porta_potty", "rallyflags", "rallysigns",
    "roadsigns", "rock_pile", "rocks", "sawhorse", "shipping_container", "spikestrip",
    "steel_coil", "trampoline", "tirewall", "trafficbarrel", "trashbin", "tub", "tube", "tv",
    "wall", "woodcrate", "woodplanks"
  }
}

return M
