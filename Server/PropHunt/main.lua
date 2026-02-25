-- ============================
-- PropHunt – SERVER MAIN LUA
-- Supports:
--   ✔ Network Taunts
--   ✔ Team System (Seekers vs Hiders)
--   ✔ Hide Phase (seeker freeze countdown)
--   ✔ Round Timer + RoundStart/RoundEnd events
--   ✔ Tagging (seekers tag hiders) + early win
--   ✔ Server-side rate limiting / cooldown enforcement
--   ✔ Configurable seekers + timings (server chat commands)
-- ============================

print("PropHunt Server-side main.lua loading...")

-- ============================
-- CONFIG (server authoritative)
-- ============================
local config = {}
do
    local ok, mod = pcall(require, "config")
    if ok and mod and mod.defaults then
        for k, v in pairs(mod.defaults) do config[k] = v end
        print("PropHunt loaded external config.lua")
    else
        print("PropHunt WARN: failed to load config.lua, using built-in fallback defaults")
        config = {
            debug = false,
            mode = "classic",
            roundTime = 300,
            hideTime  = 60,
            allowSoloTest = false,
            propPool = {"barrels", "cones", "trashbin"},
            seekerMode  = "fixed",
            seekerCount = 1,
            seekerRatio = 0.25,
            tauntCooldown = 5,
            flashCooldown = 15,
            tagCooldown = 0.0,
            scanCooldown = 0.1,
            sameTargetCooldown = 1.0,
            cleanupSweepSeconds = 15,
            tempPropSweepSeconds = 15,
            forceGhostOffOnRestore = true,
            spawnswapRetryCount = 2,
            seekerTabPrevention = true,
            hideNametagsInRound = true,
            seekerFadeDist = 120,
            seekerFilterIntensity = 1.0,
            hiderFadeDist = 120,
            hiderFilterIntensity = 0.35,
            joinPolicy = "lock_next_round",
            disguiseMode = "replace",
            nextRoundForcedProp = nil,
            adminAclEnabled = false,
            adminIds = {},
            adminNames = {},
            minEventGapTempProp = 0.05,
            minEventGapTag = 0.05,
            minEventGapTaunt = 0.05,
            minEventGapScan = 0.05,
            requireTagCorroboration = true,
            requireMutualContact = false,
            tagCorroborationWindow = 0.35,
            currentPreset = "casual",
            mapProfiles = { west_coast_usa = "ranked", utah = "casual" },
            propTierMode = "all",
            perksEnabled = true
        }
    end
end

-- Stability defaults (in case older configs omit these keys)
if config.forceGhostOffOnRestore == nil then config.forceGhostOffOnRestore = true end
if config.cleanupSweepSeconds == nil then config.cleanupSweepSeconds = tonumber(config.tempPropSweepSeconds or 15) or 15 end
if config.spawnswapRetryCount == nil then config.spawnswapRetryCount = 2 end
if config.allowSoloTest == nil then config.allowSoloTest = false end
if config.seekerTabPrevention == nil then config.seekerTabPrevention = true end
if config.hideNametagsInRound == nil then config.hideNametagsInRound = true end
if config.adminAclEnabled == nil then config.adminAclEnabled = false end
if config.adminIds == nil then config.adminIds = {} end
if config.adminNames == nil then config.adminNames = {} end
if config.minEventGapTempProp == nil then config.minEventGapTempProp = 0.05 end
if config.minEventGapTag == nil then config.minEventGapTag = 0.05 end
if config.minEventGapTaunt == nil then config.minEventGapTaunt = 0.05 end
if config.minEventGapScan == nil then config.minEventGapScan = 0.05 end
if config.requireTagCorroboration == nil then config.requireTagCorroboration = true end
if config.requireMutualContact == nil then config.requireMutualContact = false end
if config.tagCorroborationWindow == nil then config.tagCorroborationWindow = 0.35 end
if config.currentPreset == nil then config.currentPreset = "casual" end
if config.mapProfiles == nil then config.mapProfiles = {} end
if config.spawnBanks == nil then config.spawnBanks = {} end
if config.propTierMode == nil then config.propTierMode = "all" end
if config.perksEnabled == nil then config.perksEnabled = true end

local function isValidProp(key)
    for _, v in ipairs(config.propPool) do
        if tostring(v) == tostring(key) then
            return true
        end
    end
    return false
end


local function clamp(n, lo, hi)
    if n < lo then return lo end
    if n > hi then return hi end
    return n
end

local function ceil(n)
    return math.floor(n + 0.999999)
end

local function shuffleProps(props)
    local pool = {}
    for _, v in ipairs(props) do
        pool[#pool + 1] = v
    end
    for i = #pool, 2, -1 do
        local j = math.random(1, i)
        pool[i], pool[j] = pool[j], pool[i]
    end
    return pool
end

local function shuffleList(src)
    local pool = {}
    for _, v in ipairs(src) do
        pool[#pool + 1] = v
    end
    for i = #pool, 2, -1 do
        local j = math.random(1, i)
        pool[i], pool[j] = pool[j], pool[i]
    end
    return pool
end


local gameState
local pushHudPulse

local PRESET_DEFS = {
    casual = { seekerMode = "fixed", seekerCount = 1, hideTime = 60, roundTime = 300, scanCooldown = 0.15, tauntCooldown = 5, propTierMode = "all" },
    ranked = { seekerMode = "ratio", seekerRatio = 0.28, hideTime = 45, roundTime = 240, scanCooldown = 0.25, tauntCooldown = 6, sameTargetCooldown = 1.2, propTierMode = "ranked" },
    chaos = { seekerMode = "ratio", seekerRatio = 0.40, hideTime = 25, roundTime = 210, scanCooldown = 0.08, tauntCooldown = 3, sameTargetCooldown = 0.7, propTierMode = "chaos" },
}

local PROP_TIERS = {
    tiny = { ball=true, cones=true, bollard=true, delineator=true, spikestrip=true },
    hard = { trashbin=true, trafficbarrel=true, tirewall=true, sawhorse=true, roadsigns=true, rallysigns=true },
}

local function applyPreset(name)
    local p = PRESET_DEFS[tostring(name or "")]
    if not p then return false end
    for k, v in pairs(p) do config[k] = v end
    config.currentPreset = tostring(name)
    return true
end

local function propAllowedByTier(propName)
    local mode = tostring(config.propTierMode or "all")
    if mode == "all" then return true end
    local pn = tostring(propName or "")
    local tiny = PROP_TIERS.tiny[pn] == true
    local hard = PROP_TIERS.hard[pn] == true
    if mode == "ranked" then
        return (not tiny) and (not hard)
    elseif mode == "chaos" then
        return true
    end
    return true
end

local function getMapKey()
    if MP and MP.GetServerConfig and type(MP.GetServerConfig) == "function" then
        local ok, cfgObj = pcall(MP.GetServerConfig)
        if ok and type(cfgObj) == "table" then
            local m = tostring(cfgObj.Map or cfgObj.map or cfgObj.level or ""):lower()
            if m ~= "" then return m end
        end
    end
    return tostring(gameState.currentMapKey or "unknown")
end

local function resolveAndApplyMapProfile()
    local mk = getMapKey()
    gameState.currentMapKey = mk
    local preset = config.mapProfiles and config.mapProfiles[mk] or nil
    if preset and PRESET_DEFS[tostring(preset)] then
        applyPreset(preset)
        return preset
    end
    return nil
end

local function getSpawnBankForMap(mapKey)
    local mk = tostring(mapKey or ""):lower()
    local bank = config.spawnBanks and config.spawnBanks[mk] or nil
    if type(bank) ~= "table" then return nil end
    bank.seekers = type(bank.seekers) == "table" and bank.seekers or {}
    bank.hiders = type(bank.hiders) == "table" and bank.hiders or {}
    return bank
end

local function assignSpawnHints()
    local bank = getSpawnBankForMap(gameState.currentMapKey)
    if not bank then return end
    local sIdx, hIdx = 0, 0

    for pid, pdata in pairs(gameState.players or {}) do
        local list = (pdata.team == "seeker") and bank.seekers or bank.hiders
        if #list > 0 then
            if pdata.team == "seeker" then sIdx = sIdx + 1 else hIdx = hIdx + 1 end
            local idx = (pdata.team == "seeker") and (((sIdx - 1) % #list) + 1) or (((hIdx - 1) % #list) + 1)
            local sp = list[idx]
            if type(sp) == "table" and sp.x and sp.y and sp.z then
                MP.TriggerClientEvent(pid, "PropHunt_SpawnHint", string.format("%s,%0.2f,%0.2f,%0.2f", tostring(pdata.team), tonumber(sp.x) or 0, tonumber(sp.y) or 0, tonumber(sp.z) or 0))
            end
        end
    end
end

local function ensureEcon(playerId)
    local e = gameState.economy[playerId]
    if not e then
        e = { points = 0, perks = { quickScan = false, stealthTaunt = false } }
        gameState.economy[playerId] = e
    end
    return e
end

local function grantPoints(playerId, amount)
    if not config.perksEnabled then return end
    local e = ensureEcon(playerId)
    e.points = math.max(0, tonumber(e.points or 0) + tonumber(amount or 0))
    if e.points >= 30 then e.perks.quickScan = true end
    if e.points >= 20 then e.perks.stealthTaunt = true end
end

local function getEffectiveScanCooldown(playerId)
    local base = tonumber(config.scanCooldown or 0.1) or 0.1
    local e = gameState.economy[playerId]
    if e and e.perks and e.perks.quickScan then
        return math.max(0.04, base * 0.75)
    end
    return base
end

local function getEffectiveTauntCooldown(playerId)
    local base = tonumber(config.tauntCooldown or 5) or 5
    local e = gameState.economy[playerId]
    if e and e.perks and e.perks.stealthTaunt then
        return math.max(1.5, base * 0.8)
    end
    return base
end

local function computeSeekerCount(playerCount)
    if playerCount <= 1 then return 0 end

    if config.seekerMode == "ratio" then
        local c = ceil(playerCount * (config.seekerRatio or 0.25))
        c = clamp(c, 1, playerCount - 1)
        return c
    end

    -- fixed
    local c = tonumber(config.seekerCount) or 1
    c = clamp(c, 1, playerCount - 1)
    return c
end

-- ============================
-- GAME STATE
-- ============================
gameState = {
    active = false,
    phase  = "idle", -- idle | hide | round
    roundId = 0,

    roundTimer = 0,
    hideTimer  = 0,

    players = {},      -- playerID -> {name=string, team="seeker"|"hider", alive=true}
    seekerCount = 0,
    hiderCount  = 0,
    hidersAlive = 0,

    -- Manually selected seeker for next round (playerID). Used first, then cleared.
    nextSeeker = nil,   -- legacy single seeker override
    nextSeekers = nil,  -- { [playerId]=true } override for next round (supports multiple seekers)

    -- server-side per-player cooldown tracking
    lastTaunt = {},    -- playerID -> os.clock() timestamp
    lastFlash = {},
    lastTag   = {},
    lastScan  = {},
    lastTauntEvent = {},
    lastTagEvent = {},
    lastScanEvent = {},
    lastTempPropEvent = {},
    recentContactClaims = {}, -- seekerId -> targetId -> { t=now(), roundId=n, token=string|nil }
    tempProps = {}, -- playerID -> { [serverVehicleString]=true } for temporary spawned props
    lastTempPropSweepAt = 0,

    roundStartedAt = 0,
    roundTags = 0,
    roundEliminations = 0,
    roundConversions = 0,
    economy = {}, -- playerID -> {points=0, perks={...}}
    currentMapKey = "unknown"
}

local function now()
    -- os.clock() is monotonic-ish runtime seconds (good for cooldowns)
    return os.clock()
end

local function broadcast(msg)
    MP.SendChatMessage(-1, "PropHunt " .. msg)
end

local function send(playerId, msg)
    MP.SendChatMessage(playerId, "PropHunt " .. msg)
end

local function toSet(list)
    local s = {}
    if type(list) ~= "table" then return s end
    for _, v in ipairs(list) do s[tostring(v)] = true end
    return s
end

local adminIds = toSet(config.adminIds)
local adminNames = toSet(config.adminNames)

local function isAdmin(playerId, playerName)
    local sid = tostring(playerId)
    if sid == "0" or sid == "-1" then return true end
    if adminIds[sid] then return true end
    if playerName and adminNames[tostring(playerName)] then return true end
    return false
end

local function isInGame(playerId)
    return gameState.active and gameState.players[playerId] ~= nil
end

local function isAlive(playerId)
    local p = gameState.players[playerId]
    return p and p.alive == true
end

local function team(playerId)
    local p = gameState.players[playerId]
    return p and p.team or nil
end

local function countAliveHiders()
    local n = 0
    for _, p in pairs(gameState.players) do
        if p.team == "hider" and p.alive then n = n + 1 end
    end
    return n
end

local function sendHiderListToSeekers()
    if not gameState.active then return end

    local ids = {}
    for pid, pdata in pairs(gameState.players) do
        if pdata.team == "hider" and pdata.alive then
            table.insert(ids, tostring(pid))
        end
    end

    local payload = tostring(gameState.roundId)
    if #ids > 0 then
        payload = payload .. "," .. table.concat(ids, ",")
    end

    for pid, pdata in pairs(gameState.players) do
        if pdata.team == "seeker" then
            MP.TriggerClientEvent(pid, "PropHunt_HiderList", payload)
        end
    end
end

local function sendSeekerListToHiders()
    if not gameState.active then return end

    local ids = {}
    for pid, pdata in pairs(gameState.players) do
        if pdata.team == "seeker" and pdata.alive then
            table.insert(ids, tostring(pid))
        end
    end

    local payload = tostring(gameState.roundId)
    if #ids > 0 then
        payload = payload .. "," .. table.concat(ids, ",")
    end

    for pid, pdata in pairs(gameState.players) do
        if pdata.team == "hider" then
            MP.TriggerClientEvent(pid, "PropHunt_SeekerList", payload)
        end
    end
end

local function countPlayers()
    local players = MP.GetPlayers()
    local list = {}
    for playerId, playerName in pairs(players) do
        table.insert(list, { id = playerId, name = playerName })
    end
    return #list, list
end

local function formatSettingsPayload()
    local rid = tostring(gameState.roundId or 0)
    return rid
        .. "," .. tostring(config.seekerFadeDist)
        .. "," .. tostring(config.seekerFilterIntensity)
        .. "," .. tostring(config.hiderFadeDist)
        .. "," .. tostring(config.hiderFilterIntensity)
        .. "," .. tostring(config.disguiseMode or "replace")
        .. "," .. tostring(config.forceGhostOffOnRestore ~= false)
        .. "," .. tostring(math.max(1, tonumber(config.spawnswapRetryCount or 1) or 1))
        .. "," .. tostring(math.max(1, tonumber(config.cleanupSweepSeconds or config.tempPropSweepSeconds or 15) or 15))
        .. "," .. tostring(config.seekerTabPrevention ~= false)
        .. "," .. tostring(config.hideNametagsInRound ~= false)
end

local function pushSettingsToClient(playerId)
    if not playerId then return end
    MP.TriggerClientEvent(playerId, "PropHunt_Settings", formatSettingsPayload())
end

local function broadcastSettings()
    pushSettingsToClient(-1)
end

local function clearTempPropsForPlayer(pid, reason)
    local set = gameState.tempProps and gameState.tempProps[pid]
    if type(set) ~= "table" then
        gameState.tempProps[pid] = nil
        return
    end
    for serverVeh, _ in pairs(set) do
        if serverVeh and serverVeh ~= "" then
            MP.TriggerClientEvent(-1, "PropHunt_tempPropClear", tostring(serverVeh))
            if config.debug then
                print(string.format("PropHunt temp-prop cleanup: pid=%s veh=%s reason=%s", tostring(pid), tostring(serverVeh), tostring(reason or "clear")))
            end
        end
    end
    gameState.tempProps[pid] = nil
end

local function cleanupStaleTempProps(reason)
    local playersNow = MP.GetPlayers() or {}
    for pid, set in pairs(gameState.tempProps or {}) do
        local p = gameState.players and gameState.players[pid] or nil
        local connected = (playersNow[pid] ~= nil) and MP.IsPlayerConnected(pid)
        local stale = (type(set) ~= "table")
            or (not connected)
            or (not p)
            or (p.team ~= "hider")
            or (p.alive ~= true)

        if stale then
            clearTempPropsForPlayer(pid, reason or "stale")
        end
    end
end

-- ============================
-- ROUND ENDING
-- ============================
local function PropHunt_StopGameInternal(reason)
    -- reason can be: "manual" | "hiders" | "seekers" | "timeout"
    gameState.active = false
    gameState.phase = "idle"

    -- clear any temporary spawned prop vehicles on all clients
    for pid, _ in pairs(gameState.tempProps or {}) do
        clearTempPropsForPlayer(pid, "round_end")
    end

    -- tell clients the round ended + who won (used for UI/message)
    MP.TriggerClientEvent(-1, "PropHunt_RoundEnd", tostring(reason or ""))
    MP.TriggerClientEvent(-1, "PropHunt_GameEnd", tostring(reason or ""))

    if reason == "timeout" or reason == "hiders" then
        broadcast("Time's up! Hiders win!")
    elseif reason == "seekers" then
        broadcast("All hiders tagged! Seekers win!")
    elseif reason == "manual" then
        broadcast("Game ended.")
    else
        broadcast("Game ended.")
    end

    if config.perksEnabled then
        for pid, pdata in pairs(gameState.players or {}) do
            if pdata.team == "hider" and pdata.alive and (reason == "timeout" or reason == "hiders") then
                grantPoints(pid, 5)
            end
        end
    end

    local elapsed = math.max(0, math.floor((now() - (gameState.roundStartedAt or now()))))
    local mins = math.floor(elapsed / 60)
    local secs = elapsed % 60
    local winner = ((reason == "timeout" or reason == "hiders") and "HIDERS") or ((reason == "seekers") and "SEEKERS") or "NONE"
    local reasonLabel = tostring(reason or "unknown")
    broadcast(string.format("Summary: Winner=%s | Reason=%s | Preset=%s | Duration=%02d:%02d | Tags=%d | Eliminations=%d | Conversions=%d | AliveHiders=%d",
        winner,
        tostring(config.currentPreset or "custom"),
        reasonLabel,
        mins,
        secs,
        tonumber(gameState.roundTags or 0),
        tonumber(gameState.roundEliminations or 0),
        tonumber(gameState.roundConversions or 0),
        tonumber(gameState.hidersAlive or 0)
    ))

    -- reset state
    gameState.players = {}
    gameState.seekerCount = 0
    gameState.hiderCount = 0
    gameState.hidersAlive = 0
    gameState.roundTimer = 0
    gameState.hideTimer = 0
    gameState.lastTaunt = {}
    gameState.lastFlash = {}
    gameState.lastTag = {}
    gameState.lastScan = {}
    gameState.tempProps = {}
    gameState.lastTempPropSweepAt = 0
    gameState.roundStartedAt = 0

    print("PropHunt Game stopped (reason=" .. tostring(reason) .. ")")
end

function PropHunt_StopGame()
    PropHunt_StopGameInternal("manual")
end

-- ============================
-- TEAM ASSIGNMENT
-- ============================
local function pickSeekers(playerList, seekerCount)
    local chosen = {}

    -- 1) Manual override: multi-seeker list
    if gameState.nextSeekers and type(gameState.nextSeekers) == "table" then
        for _, p in ipairs(playerList) do
            if gameState.nextSeekers[p.id] then
                chosen[p.id] = true
            end
        end
        -- clear after use
        gameState.nextSeekers = nil
    end

    -- 2) Legacy single next seeker support
    if gameState.nextSeeker and not next(chosen) then
        for _, p in ipairs(playerList) do
            if p.id == gameState.nextSeeker then
                chosen[p.id] = true
                print("PropHunt Using manually selected seeker: Player " .. tostring(p.id))
                break
            end
        end
        gameState.nextSeeker = nil
    end

    -- 3) Randomly fill remaining seeker slots (shuffle to avoid repeats)
    local remaining = {}
    for _, p in ipairs(playerList) do
        if not chosen[p.id] then
            remaining[#remaining+1] = p
        end
    end
    remaining = shuffleList(remaining)
    for _, p in ipairs(remaining) do
        local current = 0
        for _ in pairs(chosen) do current = current + 1 end
        if current >= seekerCount then break end
        chosen[p.id] = true
    end

    return chosen
end

-- ============================
-- GAME START
-- ============================
function PropHunt_StartGame(optionalRoundSeconds)
    local playerCount, playerList = countPlayers()

    local minPlayers = (config.allowSoloTest == true) and 1 or 2
    if playerCount < minPlayers then
        print("PropHunt Not enough players to start game (need at least " .. tostring(minPlayers) .. ")")
        broadcast("Not enough players to start game (need at least " .. tostring(minPlayers) .. ")")
        return
    end

    -- Reset game state
    gameState.active = true
    local mapPreset = resolveAndApplyMapProfile()
    gameState.phase = "hide"
    gameState.roundId = (tonumber(gameState.roundId) or 0) + 1

    config.roundTime = tonumber(optionalRoundSeconds) or config.roundTime
    config.roundTime = clamp(config.roundTime, 30, 60 * 60) -- 30s..60m safety

    gameState.roundTimer = config.roundTime
    gameState.hideTimer  = config.hideTime

    gameState.players = {}
    gameState.seekerCount = 0
    gameState.hiderCount = 0
    gameState.hidersAlive = 0
    gameState.lastTaunt = {}
    gameState.lastFlash = {}
    gameState.lastTag = {}
    gameState.lastScan = {}
    gameState.tempProps = {}
    gameState.lastTempPropSweepAt = now()
    gameState.roundStartedAt = now()
    gameState.roundTags = 0
    gameState.roundEliminations = 0
    gameState.roundConversions = 0
    gameState.economy = {}

    local seekersNeeded = computeSeekerCount(playerCount)
    local seekerSet = pickSeekers(playerList, seekersNeeded)

    -- Assign teams
    for _, p in ipairs(playerList) do
        local t = seekerSet[p.id] and "seeker" or "hider"
        gameState.players[p.id] = { name = p.name, team = t, alive = true }
        ensureEcon(p.id)

        if t == "seeker" then
            gameState.seekerCount = gameState.seekerCount + 1
        else
            gameState.hiderCount = gameState.hiderCount + 1
            gameState.hidersAlive = gameState.hidersAlive + 1
        end
    end

    print("PropHunt Game started with " .. playerCount .. " players")
    print("PropHunt Seekers: " .. gameState.seekerCount .. " | Hiders: " .. gameState.hiderCount)

    -- Notify clients about game start + roles (include roundId)
    for playerId, pdata in pairs(gameState.players) do
        MP.TriggerClientEvent(playerId, "PropHunt_GameStart", tostring(gameState.roundId) .. "," .. tostring(pdata.team))
    end
    assignSpawnHints()

    -- E) Assign each hider a prop (server authoritative, client spawns)
    local forcedProp = config.nextRoundForcedProp

    local filteredPool = {}
    for _, p in ipairs(config.propPool or {}) do
        if propAllowedByTier(p) then filteredPool[#filteredPool + 1] = p end
    end
    if #filteredPool == 0 then filteredPool = config.propPool or {"barrels"} end
    local propCandidates = shuffleProps(filteredPool)
    local propIndex = 0
    local function getNextProp()
        propIndex = propIndex + 1
        if propIndex > #propCandidates then
            propCandidates = shuffleProps(config.propPool)
            propIndex = 1
        end
        return propCandidates[propIndex]
    end

    for playerId, pdata in pairs(gameState.players) do
        if pdata.team == "hider" then
            -- Assign ONE prop per round per hider. Persist it in server state so requestState re-sends the same.
            local propName = forcedProp or (getNextProp and getNextProp() or config.propPool[math.random(#config.propPool)])
            pdata.prop = propName
            MP.TriggerClientEvent(playerId, "PropHunt_AssignProp", tostring(gameState.roundId) .. "," .. tostring(propName))
        end
    end
    -- Next round only: clear after assignment
    config.nextRoundForcedProp = nil

    broadcastSettings()

    -- Send team lists for proximity + scan strength estimation
    sendHiderListToSeekers()
    sendSeekerListToHiders()

    -- Announce seekers
    for playerId, pdata in pairs(gameState.players) do
        if pdata.team == "seeker" then
            broadcast(pdata.name .. " is a SEEKER!")
        end
    end

    if mapPreset then
        broadcast("Map profile applied: " .. tostring(mapPreset) .. " (" .. tostring(gameState.currentMapKey) .. ")")
    end
    broadcast("Mode: " .. tostring(config.mode) .. " | Preset: " .. tostring(config.currentPreset or "custom") .. " | Hide phase: " .. tostring(gameState.hideTimer) .. " seconds.")

    -- Push vignette settings to clients
    broadcastSettings()

    -- Hide phase start + first timer push
    MP.TriggerClientEvent(-1, "PropHunt_HidePhaseStart", tostring(gameState.roundId) .. "," .. tostring(gameState.hideTimer))
    MP.TriggerClientEvent(-1, "PropHunt_HideTimerUpdate", tostring(gameState.roundId) .. "," .. tostring(gameState.hideTimer))
    if pushHudPulse then pushHudPulse() end
end

local function pushHudPulse()
    if not gameState.active then return end
    local payload = table.concat({
        tostring(gameState.roundId or 0),
        tostring(gameState.phase or "idle"),
        tostring(gameState.hidersAlive or 0),
        tostring(gameState.hiderCount or 0),
        tostring(gameState.seekerCount or 0),
        tostring(gameState.roundTimer or 0),
        tostring(gameState.hideTimer or 0),
        tostring(config.currentPreset or "custom")
    }, ",")
    MP.TriggerClientEvent(-1, "PropHunt_HudPulse", payload)
end

-- ============================
-- MAIN TICK
-- ============================
function PropHunt_onTick()
    if not gameState.active then return end

    local tNow = now()
    local sweepEvery = tonumber(config.cleanupSweepSeconds or config.tempPropSweepSeconds or 15) or 15
    if (tNow - tonumber(gameState.lastTempPropSweepAt or 0)) >= sweepEvery then
        cleanupStaleTempProps("tick")
        gameState.lastTempPropSweepAt = tNow
    end

    -- If players drop below 2 mid-game, stop.
    local playerCount = 0
    for pid, _ in pairs(MP.GetPlayers()) do
        if pid then playerCount = playerCount + 1 end
    end
    if playerCount < 2 then
        PropHunt_StopGameInternal("manual")
        return
    end

    if gameState.phase == "hide" then
        gameState.hideTimer = gameState.hideTimer - 1
        if gameState.hideTimer < 0 then gameState.hideTimer = 0 end

        MP.TriggerClientEvent(-1, "PropHunt_HideTimerUpdate", tostring(gameState.roundId) .. "," .. tostring(gameState.hideTimer))
        if pushHudPulse then pushHudPulse() end

        if gameState.hideTimer <= 0 then
            -- transition to main round
            gameState.phase = "round"
            MP.TriggerClientEvent(-1, "PropHunt_HidePhaseEnd", tostring(gameState.roundId))
            MP.TriggerClientEvent(-1, "PropHunt_RoundStart", tostring(gameState.roundId))
            broadcast("Hunt begins NOW!")

            -- Push first round timer state immediately
            MP.TriggerClientEvent(-1, "PropHunt_TimerUpdate", tostring(gameState.roundId) .. "," .. tostring(gameState.roundTimer))
        end

        return
    end

    if gameState.phase == "round" then
        gameState.roundTimer = gameState.roundTimer - 1

        if gameState.roundTimer <= 0 then
            -- Time's up! Hiders win.
            PropHunt_StopGameInternal("timeout")
            return
        end

        -- announce milestones
        if gameState.roundTimer % 60 == 0 then
            local minutes = math.floor(gameState.roundTimer / 60)
            broadcast(tostring(minutes) .. " minute(s) remaining")
        elseif gameState.roundTimer == 30 or gameState.roundTimer == 10 then
            broadcast(tostring(gameState.roundTimer) .. " seconds remaining!")
        end

        MP.TriggerClientEvent(-1, "PropHunt_TimerUpdate", tostring(gameState.roundId) .. "," .. tostring(gameState.roundTimer))
        if pushHudPulse then pushHudPulse() end

        return
    end
end

-- TIMER (BeamMP)
-- Match the Outbreak mod pattern exactly: create a 1s timer named "second".
function timer()
    PropHunt_onTick()
end

MP.RegisterEvent("second", "timer")
MP.CancelEventTimer("counter")
MP.CancelEventTimer("second")
MP.CreateEventTimer("second", 1000)

-- ============================
-- CHAT COMMANDS (server)
-- ============================
local function parseWords(msg)
    local out = {}
    for w in msg:gmatch("%S+") do table.insert(out, w) end
    return out
end

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function findPlayerIdByNameExact(name)
    name = trim(name)
    if name == "" then return nil end

    local players = MP.GetPlayers()
    for pid, pname in pairs(players) do
        if tostring(pname) == name then
            return tonumber(pid)
        end
    end

    return nil
end

local function showStatus(playerId)
    local active = tostring(gameState.active)
    local phase = tostring(gameState.phase)
    local rid = tostring(gameState.roundId)
    send(playerId, string.format("Status: active=%s phase=%s round=%s", active, phase, rid))
    send(playerId, string.format("Players: seekers=%d hiders=%d aliveHiders=%d", tonumber(gameState.seekerCount or 0), tonumber(gameState.hiderCount or 0), tonumber(gameState.hidersAlive or 0)))
    send(playerId, string.format("Timers: hide=%ds round=%ds", tonumber(gameState.hideTimer or 0), tonumber(gameState.roundTimer or 0)))
    send(playerId, string.format("Config: mode=%s seekerMode=%s seekerCount=%s seekerRatio=%s", tostring(config.mode), tostring(config.seekerMode), tostring(config.seekerCount), tostring(config.seekerRatio)))
    send(playerId, string.format("Config: hideTime=%ds roundTime=%ds joinPolicy=%s disguiseMode=%s forcedProp=%s", tonumber(config.hideTime or 60), tonumber(config.roundTime or 300), tostring(config.joinPolicy or "lock_next_round"), tostring(config.disguiseMode or "replace"), tostring(config.nextRoundForcedProp or "random")))
    send(playerId, string.format("Profiles: preset=%s map=%s propTierMode=%s perks=%s", tostring(config.currentPreset or "custom"), tostring(gameState.currentMapKey or "unknown"), tostring(config.propTierMode or "all"), tostring(config.perksEnabled == true)))
    send(playerId, string.format("Visuals: seekerFade=%.1f seekerIntensity=%.2f hiderFade=%.1f hiderIntensity=%.2f", tonumber(config.seekerFadeDist or 120), tonumber(config.seekerFilterIntensity or 1), tonumber(config.hiderFadeDist or 120), tonumber(config.hiderFilterIntensity or 0.35)))
    send(playerId, string.format("Stability: forceGhostOffOnRestore=%s cleanupSweepSeconds=%s spawnswapRetryCount=%s seekerTabPrevention=%s hideNametagsInRound=%s", tostring(config.forceGhostOffOnRestore ~= false), tostring(tonumber(config.cleanupSweepSeconds or config.tempPropSweepSeconds or 15) or 15), tostring(tonumber(config.spawnswapRetryCount or 1) or 1), tostring(config.seekerTabPrevention ~= false), tostring(config.hideNametagsInRound ~= false)))
end

local function showHelp(playerId)
    send(playerId, "Server Commands:")
    send(playerId, "  /ph start [minutes] - Start game")
    send(playerId, "  /ph stop - Stop game")
    send(playerId, "  /ph status - Round + config status")
    send(playerId, "  /ph points [playerID] - economy/perk status")
    send(playerId, "  /ph players - List player IDs")
    send(playerId, "  /ph seeker <playerID> - Set next seeker (next round)")
    send(playerId, "  /ph seekers <id1> <id2> ... - Set seekers for next round (multiple)")
    send(playerId, "  /ph seekername <username> - Set next seeker by exact username")
    send(playerId, "  /ph seekersname <name1>,<name2>,... - Set seekers by usernames (comma-separated)")
    send(playerId, "  /ph set seekers fixed <n> - Fixed number of seekers")
    send(playerId, "  /ph set seekers ratio <0-1> - Ratio of seekers")
    send(playerId, "  /ph set hidetime <seconds> - Hide phase length")
    send(playerId, "  /ph set roundtime <seconds> - Round length")
    send(playerId, "  /ph set mode classic|tag - Tagging behavior")
    send(playerId, "  /ph set joinpolicy lock_next_round|spectator|seeker|hider")
    send(playerId, "  /ph set disguisemode replace|preload|spawnswap")
    send(playerId, "  /ph set forceghostoff <on|off>")
    send(playerId, "  /ph set cleanupsweep <seconds>")
    send(playerId, "  /ph set spawnswapretry <n>")
    send(playerId, "  /ph set seekertablock <on|off>")
    send(playerId, "  /ph set nametags <on|off> - on=show tags, off=hide tags during active round")
    send(playerId, "  /ph set seekerfadedist <meters> - (Seekers) proximity vignette range")
    send(playerId, "  /ph set seekerfilterintensity <0-1> - (Seekers) vignette strength")
    send(playerId, "  /ph set hiderfadedist <meters> - (Hiders) proximity vignette range")
    send(playerId, "  /ph set hiderfilterintensity <0-1> - (Hiders) vignette strength")
    send(playerId, "  /ph preset casual|ranked|chaos")
    send(playerId, "  /ph mapprofile <mapKey> <casual|ranked|chaos>")
    send(playerId, "  /ph spawnbank add <mapKey> <seeker|hider> <x> <y> <z>")
    send(playerId, "  /ph spawnbank list <mapKey> | /ph spawnbank clear <mapKey>")
    send(playerId, "  /ph props random - Random prop per hider")
    send(playerId, "  /ph props <propKey> - Force a prop for NEXT round only")
    send(playerId, "(Old style also works: /phstart, /phstop, etc)")
end

function PropHunt_onChatMessage(playerId, playerName, message)
    local msg = tostring(message or "")

    -- Backwards compatible aliases
    if msg == "/startgame" then msg = "/phstart" end
    if msg == "/stopgame" then msg = "/phstop" end

    -- New prefix style: "/ph start" instead of "/phstart" (keep old commands working)
    if msg:match("^/ph%s+") then
        local w = parseWords(msg)
        local sub = (w[2] or ""):lower()
        local rest = ""
        if #w >= 3 then
            rest = " " .. table.concat(w, " ", 3)
        end

        local map = {
            start = "/phstart",
            stop = "/phstop",
            help = "/phhelp",
            status = "/phstatus",
            points = "/phpoints",
            players = "/phplayers",
            seeker = "/phseeker",
            seekers = "/phseekers",
            seekername = "/phseekername",
            seekersname = "/phseekersname",
            set = "/phset",
            props = "/phprops",
            preset = "/phpreset",
            mapprofile = "/phmapprofile",
            spawnbank = "/phspawnbank",
        }

        if map[sub] then
            msg = map[sub] .. rest
        end
    end

    local mutatingCmd = (
        msg == "/phstart" or msg:match("^/phstart%s") or
        msg == "/phstop" or
        msg:match("^/setseeker%s") or msg:match("^/phseeker%s") or
        msg:match("^/phseekers%s") or msg:match("^/phseekername%s") or msg:match("^/phseekersname%s") or
        msg:match("^/phset%s") or msg:match("^/phprops%s") or msg:match("^/phpreset%s") or msg:match("^/phmapprofile%s") or msg:match("^/phspawnbank%s")
    )
    if config.adminAclEnabled == true and mutatingCmd and not isAdmin(playerId, playerName) then
        send(playerId, "Admin only command")
        return 1
    end

    if msg == "/phstart" or msg:match("^/phstart%s") then
        local words = parseWords(msg)
        local minutes = tonumber(words[2])
        local secs = nil
        if minutes then secs = minutes * 60 end
        PropHunt_StartGame(secs)
        return 1
    elseif msg == "/phstop" then
        PropHunt_StopGame()
        return 1
    elseif msg:match("^/setseeker%s") or msg:match("^/phseeker%s") then
        local targetId = msg:match("%s(%d+)")
        if not targetId then
            send(playerId, "Usage: /phseeker <playerID>")
            return 1
        end

        targetId = tonumber(targetId)
        local players = MP.GetPlayers()
        if not players[targetId] then
            send(playerId, "Error: Player ID " .. tostring(targetId) .. " not found")
            return 1
        end

        gameState.nextSeeker = targetId
        gameState.nextSeekers = nil
        broadcast(players[targetId] .. " will be seeker next round!")
        print("PropHunt Player " .. tostring(targetId) .. " (" .. tostring(players[targetId]) .. ") set as next seeker")
        return 1

    elseif msg:match("^/phseekers%s") then
        local words = parseWords(msg)
        if #words < 2 then
            send(playerId, "Usage: /phseekers <id1> <id2> ...")
            return 1
        end

        local players = MP.GetPlayers()
        local set = {}
        local names = {}

        for i = 2, #words do
            local id = tonumber(words[i])
            if id and players[id] then
                set[id] = true
                table.insert(names, players[id])
            end
        end

        if not next(set) then
            send(playerId, "No valid player IDs provided")
            return 1
        end

        gameState.nextSeekers = set
        gameState.nextSeeker = nil
        broadcast("Next seekers set: " .. table.concat(names, ", "))
        return 1

    elseif msg:match("^/phseekername%s") then
        -- Everything after the command is the username (allow spaces)
        local name = trim(msg:gsub("^/phseekername%s+", ""))
        if name == "" then
            send(playerId, "Usage: /phseekername <username>")
            return 1
        end

        local pid = findPlayerIdByNameExact(name)
        if not pid then
            send(playerId, "Player not found (exact match): " .. name)
            return 1
        end

        gameState.nextSeeker = pid
        gameState.nextSeekers = nil
        broadcast(name .. " will be seeker next round!")
        return 1

    elseif msg:match("^/phseekersname%s") then
        -- Comma-separated usernames, e.g. /phseekersname Alice,Bob,Charlie
        local list = trim(msg:gsub("^/phseekersname%s+", ""))
        if list == "" then
            send(playerId, "Usage: /phseekersname <name1>,<name2>,...")
            return 1
        end

        local players = MP.GetPlayers()
        local set = {}
        local names = {}

        for raw in string.gmatch(list, "[^,]+") do
            local name = trim(raw)
            local pid = findPlayerIdByNameExact(name)
            if pid and players[pid] then
                set[pid] = true
                table.insert(names, players[pid])
            end
        end

        if not next(set) then
            send(playerId, "No valid usernames found (need exact matches)")
            return 1
        end

        gameState.nextSeekers = set
        gameState.nextSeeker = nil
        broadcast("Next seekers set: " .. table.concat(names, ", "))
        return 1

    elseif msg == "/players" or msg == "/phplayers" then
        local players = MP.GetPlayers()
        send(playerId, "Connected Players:")
        for pid, pname in pairs(players) do
            send(playerId, "  ID " .. tostring(pid) .. ": " .. tostring(pname))
        end
        return 1
    elseif msg == "/phstatus" then
        showStatus(playerId)
        return 1
    elseif msg == "/phpoints" or msg:match("^/phpoints%s") then
        local words = parseWords(msg)
        local qid = tonumber(words[2] or "") or playerId
        local e = gameState.economy[qid]
        if not e then
            send(playerId, "No economy data for player " .. tostring(qid))
            return 1
        end
        send(playerId, string.format("points[%s]=%d perks{quickScan=%s, stealthTaunt=%s}", tostring(qid), tonumber(e.points or 0), tostring(e.perks and e.perks.quickScan == true), tostring(e.perks and e.perks.stealthTaunt == true)))
        return 1
    elseif msg:match("^/phpreset%s") then
        local words = parseWords(msg)
        local preset = tostring(words[2] or ""):lower()
        if preset ~= "casual" and preset ~= "ranked" and preset ~= "chaos" then
            send(playerId, "Usage: /ph preset casual|ranked|chaos")
            return 1
        end
        applyPreset(preset)
        broadcast("Preset set to " .. tostring(preset) .. " (propTierMode=" .. tostring(config.propTierMode) .. ")")
        broadcastSettings()
        return 1
    elseif msg:match("^/phmapprofile%s") then
        local words = parseWords(msg)
        local mapKey = tostring(words[2] or ""):lower()
        local preset = tostring(words[3] or ""):lower()
        if mapKey == "" or (preset ~= "casual" and preset ~= "ranked" and preset ~= "chaos") then
            send(playerId, "Usage: /ph mapprofile <mapKey> <casual|ranked|chaos>")
            return 1
        end
        config.mapProfiles[mapKey] = preset
        send(playerId, "Map profile set: " .. mapKey .. " -> " .. preset)
        return 1
    elseif msg:match("^/phspawnbank%s") then
        local words = parseWords(msg)
        local sub = tostring(words[2] or ""):lower()
        local mapKey = tostring(words[3] or ""):lower()
        if mapKey == "" then
            send(playerId, "Usage: /ph spawnbank add|list|clear <mapKey> ...")
            return 1
        end

        config.spawnBanks[mapKey] = config.spawnBanks[mapKey] or { seekers = {}, hiders = {} }
        local bank = config.spawnBanks[mapKey]
        bank.seekers = bank.seekers or {}
        bank.hiders = bank.hiders or {}

        if sub == "clear" then
            config.spawnBanks[mapKey] = { seekers = {}, hiders = {} }
            send(playerId, "Spawn bank cleared for " .. mapKey)
            return 1
        elseif sub == "list" then
            send(playerId, string.format("Spawn bank %s: seekers=%d hiders=%d", mapKey, #bank.seekers, #bank.hiders))
            return 1
        elseif sub == "add" then
            local team = tostring(words[4] or ""):lower()
            local x, y, z = tonumber(words[5]), tonumber(words[6]), tonumber(words[7])
            if (team ~= "seeker" and team ~= "hider") or not x or not y or not z then
                send(playerId, "Usage: /ph spawnbank add <mapKey> <seeker|hider> <x> <y> <z>")
                return 1
            end
            local key = (team == "seeker") and "seekers" or "hiders"
            bank[key][#bank[key] + 1] = { x = x, y = y, z = z }
            send(playerId, string.format("Spawn added: %s[%d] on %s", key, #bank[key], mapKey))
            return 1
        else
            send(playerId, "Usage: /ph spawnbank add|list|clear <mapKey> ...")
            return 1
        end
    elseif msg == "/phhelp" then
        showHelp(playerId)
        return 1
    elseif msg:match("^/phset%s") then
        local words = parseWords(msg)
        -- /phset seekers fixed 1
        -- /phset seekers ratio 0.25
        if #words < 3 then
            showHelp(playerId)
            return 1
        end

        local key = (words[2] or ""):lower()

        if key == "seekers" then
            local mode = (words[3] or ""):lower()
            if mode == "fixed" then
                local n = tonumber(words[4])
                if not n then
                    send(playerId, "Usage: /phset seekers fixed <n>")
                    return 1
                end
                config.seekerMode = "fixed"
                config.seekerCount = clamp(math.floor(n), 1, 64)
                broadcast("Seeker mode set to fixed (" .. tostring(config.seekerCount) .. ")")
                return 1
            elseif mode == "ratio" then
                local r = tonumber(words[4])
                if not r then
                    send(playerId, "Usage: /phset seekers ratio <0-1>")
                    return 1
                end
                config.seekerMode = "ratio"
                config.seekerRatio = clamp(r, 0.01, 0.99)
                broadcast("Seeker mode set to ratio (" .. tostring(config.seekerRatio) .. ")")
                return 1
            else
                send(playerId, "Usage: /phset seekers fixed <n> OR /phset seekers ratio <0-1>")
                return 1
            end
        elseif key == "hidetime" then
            local s = tonumber(words[3])
            if not s then
                send(playerId, "Usage: /phset hidetime <seconds>")
                return 1
            end
            config.hideTime = clamp(math.floor(s), 0, 180)
            broadcast("Hide time set to " .. tostring(config.hideTime) .. "s")
            return 1
        elseif key == "roundtime" then
            local s = tonumber(words[3])
            if not s then
                send(playerId, "Usage: /phset roundtime <seconds>")
                return 1
            end
            config.roundTime = clamp(math.floor(s), 30, 60 * 60)
            broadcast("Round time set to " .. tostring(config.roundTime) .. "s")
            return 1
        elseif key == "mode" then
            local m = (words[3] or ""):lower()
            if m ~= "classic" and m ~= "tag" then
                send(playerId, "Usage: /phset mode classic OR /phset mode tag")
                return 1
            end
            config.mode = m
            broadcast("Mode set to: " .. tostring(config.mode))
            return 1
        elseif key == "joinpolicy" then
            local p = tostring(words[3] or ""):lower()
            if p ~= "lock_next_round" and p ~= "spectator" and p ~= "seeker" and p ~= "hider" then
                send(playerId, "Usage: /phset joinpolicy lock_next_round|spectator|seeker|hider")
                return 1
            end
            config.joinPolicy = p
            broadcast("Join policy set to: " .. tostring(config.joinPolicy))
            return 1
        elseif key == "disguisemode" then
            local d = tostring(words[3] or ""):lower()
            if d ~= "replace" and d ~= "preload" and d ~= "spawnswap" then
                send(playerId, "Usage: /phset disguisemode replace|preload|spawnswap")
                return 1
            end
            config.disguiseMode = d
            broadcast("Disguise mode set to: " .. tostring(config.disguiseMode))
            broadcastSettings()
            return 1
        elseif key == "forceghostoff" then
            local v = tostring(words[3] or ""):lower()
            if v ~= "on" and v ~= "off" then
                send(playerId, "Usage: /phset forceghostoff <on|off>")
                return 1
            end
            config.forceGhostOffOnRestore = (v == "on")
            broadcast("forceGhostOffOnRestore=" .. tostring(config.forceGhostOffOnRestore))
            broadcastSettings()
            return 1
        elseif key == "cleanupsweep" then
            local s = tonumber(words[3])
            if not s then
                send(playerId, "Usage: /phset cleanupsweep <seconds>")
                return 1
            end
            config.cleanupSweepSeconds = clamp(math.floor(s), 1, 600)
            config.tempPropSweepSeconds = config.cleanupSweepSeconds
            broadcast("cleanupSweepSeconds=" .. tostring(config.cleanupSweepSeconds))
            broadcastSettings()
            return 1
        elseif key == "spawnswapretry" then
            local n = tonumber(words[3])
            if not n then
                send(playerId, "Usage: /phset spawnswapretry <n>")
                return 1
            end
            config.spawnswapRetryCount = clamp(math.floor(n), 1, 10)
            broadcast("spawnswapRetryCount=" .. tostring(config.spawnswapRetryCount))
            broadcastSettings()
            return 1
        elseif key == "seekertablock" then
            local v = tostring(words[3] or ""):lower()
            if v ~= "on" and v ~= "off" then
                send(playerId, "Usage: /phset seekertablock <on|off>")
                return 1
            end
            config.seekerTabPrevention = (v == "on")
            broadcast("seekerTabPrevention=" .. tostring(config.seekerTabPrevention))
            broadcastSettings()
            return 1
        elseif key == "nametags" then
            local v = tostring(words[3] or ""):lower()
            if v ~= "on" and v ~= "off" then
                send(playerId, "Usage: /phset nametags <on|off>")
                return 1
            end
            -- Human-friendly: nametags off => hide tags during round.
            config.hideNametagsInRound = (v == "off")
            broadcast("hideNametagsInRound=" .. tostring(config.hideNametagsInRound) .. " (nametags " .. v .. ")")
            broadcastSettings()
            return 1
        elseif key == "seekerfadedist" then
            local m = tonumber(words[3])
            if not m then
                send(playerId, "Usage: /phset seekerfadedist <meters>")
                return 1
            end
            config.seekerFadeDist = clamp(m, 5, 2000)
            broadcast("Seeker fade distance set to: " .. tostring(config.seekerFadeDist) .. "m")
            broadcastSettings()
            return 1
        elseif key == "seekerfilterintensity" then
            local v = tonumber(words[3])
            if not v then
                send(playerId, "Usage: /phset seekerfilterintensity <0-1>")
                return 1
            end
            config.seekerFilterIntensity = clamp(v, 0, 1)
            broadcast("Seeker filter intensity set to: " .. tostring(config.seekerFilterIntensity))
            broadcastSettings()
            return 1
        elseif key == "hiderfadedist" then
            local m = tonumber(words[3])
            if not m then
                send(playerId, "Usage: /phset hiderfadedist <meters>")
                return 1
            end
            config.hiderFadeDist = clamp(m, 5, 2000)
            broadcast("Hider fade distance set to: " .. tostring(config.hiderFadeDist) .. "m")
            broadcastSettings()
            return 1
        elseif key == "hiderfilterintensity" then
            local v = tonumber(words[3])
            if not v then
                send(playerId, "Usage: /phset hiderfilterintensity <0-1>")
                return 1
            end
            config.hiderFilterIntensity = clamp(v, 0, 1)
            broadcast("Hider filter intensity set to: " .. tostring(config.hiderFilterIntensity))
            broadcastSettings()
            return 1
        else
            showHelp(playerId)
            return 1
        end
    elseif msg:match("^/phprops%s") then
        local words = parseWords(msg)
        local arg = (words[2] or "")
        if arg == "" then
            send(playerId, "Usage: /phprops random OR /phprops <propKey>")
            return 1
        end

        if arg == "random" then
            config.nextRoundForcedProp = nil
            send(playerId, "Prop mode: random")
            return 1
        end

        if not isValidProp(arg) then
            send(playerId, "Unknown prop key: " .. tostring(arg))
            return 1
        end
        if not propAllowedByTier(arg) then
            send(playerId, "Prop is blocked by current propTierMode (" .. tostring(config.propTierMode or "all") .. ")")
            return 1
        end

        -- Force for NEXT ROUND ONLY
        config.nextRoundForcedProp = arg
        send(playerId, "Next round prop forced to: " .. tostring(arg))
        return 1
    end

    return 0
end

MP.RegisterEvent("onChatMessage", "PropHunt_onChatMessage")

-- ============================
-- CLIENT READY / STATE SYNC (fixes late-join / late-loaded client extensions)
-- ============================
function PropHunt_clientReady(playerId, data)
    -- no-op for now; could track responded clients
end
MP.RegisterEvent("PropHunt_clientReady", "PropHunt_clientReady")

function PropHunt_requestState(playerId, data)
    if not gameState.active then return end
    local p = gameState.players[playerId]
    if not p then return end

    -- Send role
    MP.TriggerClientEvent(playerId, "PropHunt_GameStart", tostring(gameState.roundId) .. "," .. tostring(p.team))

    -- Send prop assignment (hiders)
    if p.team == "hider" then
        -- Ensure a prop exists even if this player joined late / state got reset
        if not p.prop or tostring(p.prop) == "" then
            p.prop = config.propPool[math.random(#config.propPool)]
        end
        MP.TriggerClientEvent(playerId, "PropHunt_AssignProp", tostring(gameState.roundId) .. "," .. tostring(p.prop))
    end

    -- Send phase/timers
    if gameState.phase == "hide" then
        MP.TriggerClientEvent(playerId, "PropHunt_HidePhaseStart", tostring(gameState.roundId) .. "," .. tostring(gameState.hideTimer))
        MP.TriggerClientEvent(playerId, "PropHunt_HideTimerUpdate", tostring(gameState.roundId) .. "," .. tostring(gameState.hideTimer))
    elseif gameState.phase == "round" then
        MP.TriggerClientEvent(playerId, "PropHunt_HidePhaseEnd", tostring(gameState.roundId))
        MP.TriggerClientEvent(playerId, "PropHunt_RoundStart", tostring(gameState.roundId))
        MP.TriggerClientEvent(playerId, "PropHunt_TimerUpdate", tostring(gameState.roundId) .. "," .. tostring(gameState.roundTimer))
    end

    pushSettingsToClient(playerId)
end
MP.RegisterEvent("PropHunt_requestState", "PropHunt_requestState")

-- Forward declaration (used by PropHunt_tempPropSet before helper section is defined)
local isEventFlood

-- Temporary spawned prop registration (for cleanup on all clients)
function PropHunt_tempPropSet(playerId, data)
    if isEventFlood(gameState.lastTempPropEvent, playerId, config.minEventGapTempProp) then return end
    local raw = tostring(data or "")
    if raw == "" then return end
    if #raw > 128 then return end

    local ridStr, sv = raw:match("^(%d+)%|(.+)$")
    local rid = tonumber(ridStr)
    local serverVeh = tostring(sv or raw)

    if serverVeh == "" then return end
    if rid and ((not gameState.active) or rid ~= tonumber(gameState.roundId or -1)) then
        if config.debug then
            print(string.format("PropHunt temp-prop ignore stale report: pid=%s rid=%s current=%s veh=%s", tostring(playerId), tostring(rid), tostring(gameState.roundId), tostring(serverVeh)))
        end
        return
    end

    gameState.tempProps = gameState.tempProps or {}
    gameState.tempProps[playerId] = gameState.tempProps[playerId] or {}
    gameState.tempProps[playerId][serverVeh] = true
end
MP.RegisterEvent("PropHunt_tempPropSet", "PropHunt_tempPropSet")

-- ============================
-- RATE LIMIT HELPERS
-- ============================
local function isOnCooldown(map, playerId, cooldownSeconds)
    local t = now()
    local last = map[playerId] or -1e9
    if (t - last) < cooldownSeconds then
        return true, (cooldownSeconds - (t - last))
    end
    map[playerId] = t
    return false, 0
end

isEventFlood = function(map, playerId, minGap)
    local t = now()
    local last = map[playerId] or -1e9
    if (t - last) < (tonumber(minGap) or 0.05) then
        return true
    end
    map[playerId] = t
    return false
end

local function recordContactClaim(fromPlayerId, targetPlayerId, roundId, token)
    if not fromPlayerId or not targetPlayerId then return end
    gameState.recentContactClaims[fromPlayerId] = gameState.recentContactClaims[fromPlayerId] or {}
    gameState.recentContactClaims[fromPlayerId][targetPlayerId] = {
        t = now(),
        roundId = tonumber(roundId) or tonumber(gameState.roundId or -1),
        token = token and tostring(token) or nil,
    }
end

local function hasRecentContactClaim(fromPlayerId, targetPlayerId, roundId)
    local byFrom = gameState.recentContactClaims[fromPlayerId]
    if not byFrom then return false end
    local claim = byFrom[targetPlayerId]
    if not claim then return false end

    local maxAge = tonumber(config.tagCorroborationWindow or 0.35) or 0.35
    if (now() - (claim.t or -1e9)) > maxAge then return false end
    if tonumber(claim.roundId or -1) ~= tonumber(roundId or -2) then return false end
    return true
end

-- ============================
-- TAUNT EVENT
-- ============================
-- Client calls: TriggerServerEvent("PropHunt_TauntRequest", payload)
-- payload is preferred as serverVehicleString ("<ownerPid>-<vehIdx>"); legacy numeric vehID still accepted.
-- Server broadcasts to all: "PropHunt_Taunt" => payload
--
-- Rules:
--  - Allowed any time
--  - Server enforces per-player cooldown
-- ============================
function PropHunt_onTauntRequest(playerId, data)
    if isEventFlood(gameState.lastTauntEvent, playerId, config.minEventGapTaunt) then return end
    local payload = tostring(data or "")
    if #payload > 64 then return end
    local isServerVeh = payload:match("^%d+%-%d+$") ~= nil
    local vehId = tonumber(payload)
    if (not isServerVeh) and (not vehId) then
        print("PropHunt TauntRequest ERROR: invalid payload")
        return
    end
    if not gameState.active then return end
    if not isInGame(playerId) then
        if config.debug then print("PropHunt TauntRequest rejected: player not in game") end
        return
    end
    local tauntCd = getEffectiveTauntCooldown(playerId)
    local cd, remaining = isOnCooldown(gameState.lastTaunt, playerId, tauntCd)
    if cd then
        return
    end

    if team(playerId) == "hider" then
        grantPoints(playerId, 1)
    end

    MP.TriggerClientEvent(-1, "PropHunt_Taunt", payload)
end

MP.RegisterEvent("PropHunt_TauntRequest", "PropHunt_onTauntRequest")

-- ============================
-- TAG EVENT (seekers tag hiders)
-- ============================
-- Client calls: TriggerServerEvent("PropHunt_TagRequest", targetPlayerId)
-- Server validates teams + alive state, then eliminates hider.
-- (Distance checks are not currently possible server-side without position APIs;
--  we assume the client only sends valid tags. Later we can add client-side distance checks.)
-- ============================
function PropHunt_onTagRequest(playerId, data)
    if isEventFlood(gameState.lastTagEvent, playerId, config.minEventGapTag) then return end
    local raw = tostring(data or "")
    if #raw > 96 then return end

    local reqRoundId = tonumber(gameState.roundId or -1)
    local targetId = nil
    local reqToken = nil

    if raw:find("|", 1, true) then
        local a, b, c = raw:match("^([^|]+)|([^|]+)|?(.*)$")
        if a and b then
            local r = tonumber(a)
            local t = tonumber(b)
            if r then reqRoundId = r end
            targetId = t
            if c and c ~= "" then reqToken = tostring(c) end
        end
    else
        targetId = tonumber(raw)
    end

    if not targetId then return end

    if config.debug then
        print(string.format("PropHunt[TAG] seekerPid=%s targetPid=%s phase=%s", tostring(playerId), tostring(targetId), tostring(gameState.phase)))
    end

    if not gameState.active or gameState.phase ~= "round" then
        if config.debug then print("PropHunt[TAG] rejected: game not active/round") end
        return
    end

    if not isInGame(playerId) or not isAlive(playerId) then
        if config.debug then print("PropHunt[TAG] rejected: seeker not in game/alive") end
        return
    end

    if team(playerId) ~= "seeker" then
        if config.debug then print("PropHunt[TAG] rejected: seeker team mismatch") end
        return
    end

    -- Prevent repeatedly tagging the same target in a short window (spam collisions)
    gameState.lastTaggedTarget = gameState.lastTaggedTarget or {}
    local lastTarget = gameState.lastTaggedTarget[playerId] or {}
    local lastTgtId = lastTarget.id
    local lastTgtAt = lastTarget.t or -1e9
    local dtSame = now() - lastTgtAt
    if lastTgtId == targetId and dtSame < (tonumber(config.sameTargetCooldown) or 1.0) then
        if config.debug then print("PropHunt[TAG] rejected: same target spam") end
        return
    end

    -- Optional global seeker cooldown (kept at 0 by default)
    local cd = isOnCooldown(gameState.lastTag, playerId, config.tagCooldown)
    if cd then
        if config.debug then print("PropHunt[TAG] rejected: seeker cooldown") end
        return
    end

    if targetId == playerId then
        if config.debug then print("PropHunt[TAG] rejected: self-target") end
        return
    end

    if not isInGame(targetId) or not isAlive(targetId) then
        if config.debug then print("PropHunt[TAG] rejected: target not in game/alive") end
        return
    end

    if team(targetId) ~= "hider" then
        if config.debug then print("PropHunt[TAG] rejected: target not a hider") end
        return
    end

    -- Corroboration path: require recent contact claim(s) before accepting tag.
    if config.requireTagCorroboration ~= false then
        local roundNow = tonumber(gameState.roundId or -1)
        local aToB = hasRecentContactClaim(playerId, targetId, roundNow)
        local bToA = hasRecentContactClaim(targetId, playerId, roundNow)

        if config.requireMutualContact == true then
            if not (aToB and bToA) then
                if config.debug then print("PropHunt[TAG] rejected: missing mutual contact corroboration") end
                return
            end
        else
            if not (aToB or bToA) then
                if config.debug then print("PropHunt[TAG] rejected: missing contact corroboration") end
                return
            end
        end
    end

    -- record last target for anti-spam
    gameState.lastTaggedTarget[playerId] = { id = targetId, t = now(), token = reqToken }
    gameState.roundTags = (gameState.roundTags or 0) + 1

    grantPoints(playerId, 3) -- seeker successful tag bonus

    local seekerName = gameState.players[playerId].name or (MP.GetPlayerName(playerId) or tostring(playerId))
    local hiderName  = gameState.players[targetId].name or (MP.GetPlayerName(targetId) or tostring(targetId))

    if config.mode == "tag" then
        -- Convert hider -> seeker (still alive)
        gameState.players[targetId].team = "seeker"
        gameState.players[targetId].alive = true
        gameState.hidersAlive = countAliveHiders()
        gameState.roundConversions = (gameState.roundConversions or 0) + 1

        broadcast(seekerName .. " converted " .. hiderName .. "!")

        -- Tell that player their team changed
        MP.TriggerClientEvent(targetId, "PropHunt_TeamUpdate", tostring(gameState.roundId) .. ",seeker")
        MP.TriggerClientEvent(targetId, "PropHunt_KillcamPulse", tostring(gameState.roundId) .. "," .. tostring(seekerName) .. "," .. tostring(hiderName))

        -- Update team lists
        sendHiderListToSeekers()
        sendSeekerListToHiders()

        if gameState.hidersAlive <= 0 then
            PropHunt_StopGameInternal("seekers")
        end

    else
        -- Classic: eliminate hider
        gameState.players[targetId].alive = false
        gameState.hidersAlive = countAliveHiders()
        gameState.roundEliminations = (gameState.roundEliminations or 0) + 1

        broadcast(seekerName .. " tagged " .. hiderName .. "!")

        -- notify clients for UI
        MP.TriggerClientEvent(-1, "PropHunt_PlayerEliminated", tostring(targetId) .. "," .. tostring(hiderName))
        MP.TriggerClientEvent(targetId, "PropHunt_KillcamPulse", tostring(gameState.roundId) .. "," .. tostring(seekerName) .. "," .. tostring(hiderName))

        clearTempPropsForPlayer(targetId, "tagged")

        -- Update team lists
        sendHiderListToSeekers()
        sendSeekerListToHiders()

        if gameState.hidersAlive <= 0 then
            PropHunt_StopGameInternal("seekers")
        end
    end
end

-- Outbreak-style contact corroboration event
function PropHunt_onContactReceive(playerId, data)
    local raw = tostring(data or "")
    if raw == "" or #raw > 128 then return end

    -- accepted payloads:
    --   "<targetId>"
    --   "<roundId>|<targetId>"
    --   "<roundId>|<targetId>|<token>"
    local rid = tonumber(gameState.roundId or -1)
    local targetId = nil
    local token = nil

    if raw:find("|", 1, true) then
        local a, b, c = raw:match("^([^|]+)|([^|]+)|?(.*)$")
        if a and b then
            rid = tonumber(a) or rid
            targetId = tonumber(b)
            if c and c ~= "" then token = tostring(c) end
        end
    else
        targetId = tonumber(raw)
    end

    if not targetId then return end
    if not gameState.active or gameState.phase ~= "round" then return end
    if not isInGame(playerId) or not isInGame(targetId) then return end

    recordContactClaim(playerId, targetId, rid, token)

    -- Back-compat path: older clients used contact as immediate tag request.
    PropHunt_onTagRequest(playerId, tostring(rid) .. "|" .. tostring(targetId) .. (token and ("|" .. token) or ""))
end
MP.RegisterEvent("PropHunt_onContactReceive", "PropHunt_onContactReceive")

-- Backwards compatible tag request event
MP.RegisterEvent("PropHunt_TagRequest", "PropHunt_onTagRequest")

-- ============================
-- SEEKER SCAN EVENT
-- ============================
-- Client calls: TriggerServerEvent("PropHunt_ScanRequest", "")
-- Server validates teams + alive state + cooldown, then tells that seeker to run a local scan pulse.
function PropHunt_onScanRequest(playerId, data)
    if isEventFlood(gameState.lastScanEvent, playerId, config.minEventGapScan) then return end
    if not gameState.active or gameState.phase ~= "round" then return end
    if not isInGame(playerId) or not isAlive(playerId) then return end
    if team(playerId) ~= "seeker" then return end

    local scanCd = getEffectiveScanCooldown(playerId)
    local cd, remaining = isOnCooldown(gameState.lastScan, playerId, scanCd)
    if cd then
        if remaining and remaining > 0.2 then
            MP.TriggerClientEvent(playerId, "PropHunt_CooldownHint", "scan," .. string.format("%.2f", remaining))
            send(playerId, string.format("Scan cooldown: %.1fs", remaining))
        end
        return
    end

    MP.TriggerClientEvent(playerId, "PropHunt_ScanPulse", tostring(gameState.roundId))
end
MP.RegisterEvent("PropHunt_ScanRequest", "PropHunt_onScanRequest")

-- ============================
-- JOIN / DISCONNECT HANDLERS
-- ============================
function PropHunt_onPlayerJoin(playerId)
    if not gameState.active then return end

    local policy = tostring(config.joinPolicy or "lock_next_round")
    if policy == "lock_next_round" or policy == "spectator" then
        send(playerId, "Round in progress. You're join-locked and will play next round.")
        return
    end

    local name = MP.GetPlayerName(playerId) or ("Player " .. tostring(playerId))
    local teamAssigned = (policy == "hider") and "hider" or "seeker"
    local alive = true

    gameState.players[playerId] = { name = name, team = teamAssigned, alive = alive }
    if teamAssigned == "hider" then
        gameState.hiderCount = gameState.hiderCount + 1
        gameState.hidersAlive = gameState.hidersAlive + 1
    else
        gameState.seekerCount = gameState.seekerCount + 1
    end

    MP.TriggerClientEvent(playerId, "PropHunt_GameStart", tostring(gameState.roundId) .. "," .. tostring(teamAssigned))
    if gameState.phase == "hide" then
        MP.TriggerClientEvent(playerId, "PropHunt_HidePhaseStart", tostring(gameState.roundId) .. "," .. tostring(gameState.hideTimer))
        MP.TriggerClientEvent(playerId, "PropHunt_HideTimerUpdate", tostring(gameState.roundId) .. "," .. tostring(gameState.hideTimer))
    elseif gameState.phase == "round" then
        MP.TriggerClientEvent(playerId, "PropHunt_HidePhaseEnd", tostring(gameState.roundId))
        MP.TriggerClientEvent(playerId, "PropHunt_RoundStart", tostring(gameState.roundId))
        MP.TriggerClientEvent(playerId, "PropHunt_TimerUpdate", tostring(gameState.roundId) .. "," .. tostring(gameState.roundTimer))
    end

    if teamAssigned == "hider" then
        local propName = config.nextRoundForcedProp or config.propPool[math.random(#config.propPool)]
        gameState.players[playerId].prop = propName
        MP.TriggerClientEvent(playerId, "PropHunt_AssignProp", tostring(gameState.roundId) .. "," .. tostring(propName))
    end

    pushSettingsToClient(playerId)
    sendHiderListToSeekers()
    sendSeekerListToHiders()
    broadcast(name .. " joined mid-round as " .. string.upper(teamAssigned))
end

function PropHunt_onPlayerDisconnect(playerId)
    if not gameState.active then return end

    clearTempPropsForPlayer(playerId, "disconnect")
    -- owner-fallback cleanup disabled (could remove live vehicles)

    if gameState.players[playerId] then
        gameState.players[playerId] = nil
        gameState.hidersAlive = countAliveHiders()

        -- Update team lists
        sendHiderListToSeekers()
        sendSeekerListToHiders()

        -- If no hiders remain, seekers win.
        if gameState.phase == "round" and gameState.hidersAlive <= 0 then
            PropHunt_StopGameInternal("seekers")
        end
    end

    cleanupStaleTempProps("disconnect")
end

MP.RegisterEvent("onPlayerJoin", "PropHunt_onPlayerJoin")
MP.RegisterEvent("onPlayerDisconnect", "PropHunt_onPlayerDisconnect")

print("PropHunt Server-side main.lua loaded successfully.")
