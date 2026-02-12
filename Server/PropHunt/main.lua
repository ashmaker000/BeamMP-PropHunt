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
            propPool = {"barrels", "cones", "trashbin"},
            seekerMode  = "fixed",
            seekerCount = 1,
            seekerRatio = 0.25,
            tauntCooldown = 5,
            flashCooldown = 15,
            tagCooldown = 0.0,
            scanCooldown = 0.1,
            sameTargetCooldown = 1.0,
            seekerFadeDist = 120,
            seekerFilterIntensity = 1.0,
            hiderFadeDist = 120,
            hiderFilterIntensity = 0.35,
            joinPolicy = "lock_next_round",
            disguiseMode = "replace",
            nextRoundForcedProp = nil
        }
    end
end

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
local gameState = {
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
    tempProps = {}, -- playerID -> serverVehicleString for temporary spawned prop

    roundStartedAt = 0,
    roundTags = 0,
    roundEliminations = 0,
    roundConversions = 0
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
    return rid .. "," .. tostring(config.seekerFadeDist) .. "," .. tostring(config.seekerFilterIntensity) .. "," .. tostring(config.hiderFadeDist) .. "," .. tostring(config.hiderFilterIntensity) .. "," .. tostring(config.disguiseMode or "replace")
end

local function pushSettingsToClient(playerId)
    if not playerId then return end
    MP.TriggerClientEvent(playerId, "PropHunt_Settings", formatSettingsPayload())
end

local function broadcastSettings()
    pushSettingsToClient(-1)
end

-- ============================
-- ROUND ENDING
-- ============================
local function PropHunt_StopGameInternal(reason)
    -- reason can be: "manual" | "hiders" | "seekers" | "timeout"
    gameState.active = false
    gameState.phase = "idle"

    -- clear any temporary spawned prop vehicles on all clients
    for _, serverVeh in pairs(gameState.tempProps or {}) do
        if serverVeh and serverVeh ~= "" then
            MP.TriggerClientEvent(-1, "PropHunt_tempPropClear", tostring(serverVeh))
        end
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

    local elapsed = math.max(0, math.floor((now() - (gameState.roundStartedAt or now()))))
    local mins = math.floor(elapsed / 60)
    local secs = elapsed % 60
    local winner = ((reason == "timeout" or reason == "hiders") and "HIDERS") or ((reason == "seekers") and "SEEKERS") or "NONE"
    local reasonLabel = tostring(reason or "unknown")
    broadcast(string.format("Summary: Winner=%s | Reason=%s | Duration=%02d:%02d | Tags=%d | Eliminations=%d | Conversions=%d | AliveHiders=%d",
        winner,
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

    if playerCount < 2 then
        print("PropHunt Not enough players to start game (need at least 2)")
        broadcast("Not enough players to start game (need at least 2)")
        return
    end

    -- Reset game state
    gameState.active = true
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
    gameState.roundStartedAt = now()
    gameState.roundTags = 0
    gameState.roundEliminations = 0
    gameState.roundConversions = 0

    local seekersNeeded = computeSeekerCount(playerCount)
    local seekerSet = pickSeekers(playerList, seekersNeeded)

    -- Assign teams
    for _, p in ipairs(playerList) do
        local t = seekerSet[p.id] and "seeker" or "hider"
        gameState.players[p.id] = { name = p.name, team = t, alive = true }

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

    -- E) Assign each hider a prop (server authoritative, client spawns)
    local forcedProp = config.nextRoundForcedProp

    local propCandidates = shuffleProps(config.propPool)
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

    broadcast("Mode: " .. tostring(config.mode) .. " | Hide phase: " .. tostring(gameState.hideTimer) .. " seconds.")

    -- Push vignette settings to clients
    broadcastSettings()

    -- Hide phase start + first timer push
    MP.TriggerClientEvent(-1, "PropHunt_HidePhaseStart", tostring(gameState.roundId) .. "," .. tostring(gameState.hideTimer))
    MP.TriggerClientEvent(-1, "PropHunt_HideTimerUpdate", tostring(gameState.roundId) .. "," .. tostring(gameState.hideTimer))
end

-- ============================
-- MAIN TICK
-- ============================
function PropHunt_onTick()
    if not gameState.active then return end

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
    send(playerId, string.format("Visuals: seekerFade=%.1f seekerIntensity=%.2f hiderFade=%.1f hiderIntensity=%.2f", tonumber(config.seekerFadeDist or 120), tonumber(config.seekerFilterIntensity or 1), tonumber(config.hiderFadeDist or 120), tonumber(config.hiderFilterIntensity or 0.35)))
end

local function showHelp(playerId)
    send(playerId, "Server Commands:")
    send(playerId, "  /ph start [minutes] - Start game")
    send(playerId, "  /ph stop - Stop game")
    send(playerId, "  /ph status - Round + config status")
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
    send(playerId, "  /ph set seekerfadedist <meters> - (Seekers) proximity vignette range")
    send(playerId, "  /ph set seekerfilterintensity <0-1> - (Seekers) vignette strength")
    send(playerId, "  /ph set hiderfadedist <meters> - (Hiders) proximity vignette range")
    send(playerId, "  /ph set hiderfilterintensity <0-1> - (Hiders) vignette strength")
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
            players = "/phplayers",
            seeker = "/phseeker",
            seekers = "/phseekers",
            seekername = "/phseekername",
            seekersname = "/phseekersname",
            set = "/phset",
            props = "/phprops",
        }

        if map[sub] then
            msg = map[sub] .. rest
        end
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

-- Temporary spawned prop registration (for cleanup on all clients)
function PropHunt_tempPropSet(playerId, data)
    local serverVeh = tostring(data or "")
    if serverVeh == "" then return end
    gameState.tempProps = gameState.tempProps or {}
    gameState.tempProps[playerId] = serverVeh
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

-- ============================
-- TAUNT EVENT
-- ============================
-- Client calls: TriggerServerEvent("PropHunt_TauntRequest", vehID)
-- Server broadcasts to all: "PropHunt_Taunt" => vehID
--
-- Rules:
--  - Allowed any time
--  - Server enforces per-player cooldown
-- ============================
function PropHunt_onTauntRequest(playerId, data)
    local vehId = tonumber(data)
    if not vehId then
        print("PropHunt TauntRequest ERROR: invalid vehId")
        return
    end
    if not gameState.active then return end
    if not isInGame(playerId) then
        if config.debug then print("PropHunt TauntRequest rejected: player not in game") end
        return
    end
    local cd, remaining = isOnCooldown(gameState.lastTaunt, playerId, config.tauntCooldown)
    if cd then
        return
    end

    MP.TriggerClientEvent(-1, "PropHunt_Taunt", tostring(vehId))
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
    local targetId = tonumber(data)
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

    -- record last target for anti-spam
    gameState.lastTaggedTarget[playerId] = { id = targetId, t = now() }
    gameState.roundTags = (gameState.roundTags or 0) + 1

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

        local tempServerVeh = gameState.tempProps and gameState.tempProps[targetId]
        if tempServerVeh and tempServerVeh ~= "" then
            MP.TriggerClientEvent(-1, "PropHunt_tempPropClear", tostring(tempServerVeh))
            gameState.tempProps[targetId] = nil
        end

        -- Update team lists
        sendHiderListToSeekers()
        sendSeekerListToHiders()

        if gameState.hidersAlive <= 0 then
            PropHunt_StopGameInternal("seekers")
        end
    end
end

-- Outbreak-style alias: "contact" event
function PropHunt_onContactReceive(playerId, data)
    -- data: targetPlayerId
    PropHunt_onTagRequest(playerId, data)
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
    if not gameState.active or gameState.phase ~= "round" then return end
    if not isInGame(playerId) or not isAlive(playerId) then return end
    if team(playerId) ~= "seeker" then return end

    local cd, remaining = isOnCooldown(gameState.lastScan, playerId, config.scanCooldown)
    if cd then
        -- Give a lightweight hint so it doesn't feel "broken"
        if remaining and remaining > 0.2 then
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
end

MP.RegisterEvent("onPlayerJoin", "PropHunt_onPlayerJoin")
MP.RegisterEvent("onPlayerDisconnect", "PropHunt_onPlayerDisconnect")

print("PropHunt Server-side main.lua loaded successfully.")
