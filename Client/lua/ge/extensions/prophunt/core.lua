-- lua/ge/extensions/PropHunt.lua
local M = {}

-- --- CONFIG ---
local TAUNT_INTERVAL = 30
local AUTO_TAUNT_ENABLED = false -- disable auto taunt (horn) by default
local TAUNT_SOUND_DISTANCE = 50 -- how far taunts can be heard (reduced from 150)

local SOUND_VOLUME = 1
local MAX_SOUND_LENGTH = 10

local TAUNT_SOUNDS_DIR = "art/Sounds/Taunts/all"

local function requireMod(dotted, slashed)
    local ok, mod = pcall(require, dotted)
    if ok and mod then return mod end
    ok, mod = pcall(require, slashed)
    if ok and mod then return mod end
    error("PropHunt module load failed: " .. tostring(dotted) .. " / " .. tostring(slashed) .. " => " .. tostring(mod))
end

local util = requireMod("ge.extensions.prophunt.util", "ge/extensions/prophunt/util")
local visuals = requireMod("ge.extensions.prophunt.visuals", "ge/extensions/prophunt/visuals")
local audioFactory = requireMod("ge.extensions.prophunt.audio", "ge/extensions/prophunt/audio")
local commandMod = requireMod("ge.extensions.prophunt.commands", "ge/extensions/prophunt/commands")
local networkMod = requireMod("ge.extensions.prophunt.network", "ge/extensions/prophunt/network")
local disguiseMod = requireMod("ge.extensions.prophunt.disguise", "ge/extensions/prophunt/disguise")
local proximityFactory = requireMod("ge.extensions.prophunt.proximity", "ge/extensions/prophunt/proximity")
local phAudio = audioFactory.new({
    tauntDir = TAUNT_SOUNDS_DIR,
    tauntDistance = TAUNT_SOUND_DISTANCE,
    volume = SOUND_VOLUME,
    maxLength = MAX_SOUND_LENGTH,
})

-- --- STATE ---
local runnerID = nil
local propID = nil
local isHidden = false
local tauntTimer = 0
local uiTimer = 0

-- UI flash overlay timer (seekers only)
local flashUiTimer = 0

local function beamMessage(opts)
    util.beamMessage(opts)
end

-- --- GAME STATE ---
local playerTeam = nil -- "seeker" or "hider"
local gameActive = false
local gameTimer = 0
local lastGameTimer = 0 -- track previous timer value for notifications
-- sound emitter readiness managed by phAudio
local hidePhase = false -- True during 20-second hide countdown
local hideTimer = 0
local assignedPropName = nil
local lastHandledGameStartRound = nil
local lastHandledHidePhaseStartRound = nil
local lastHandledHidePhaseEndRound = nil
local propStateRequestedRound = nil

-- proximity state/queries moved to prophunt/proximity.lua
local proximity = nil

-- Seeker proximity vignette settings (server-sent)
local seekerFadeDist = 120
local seekerFilterIntensity = 0.35

-- Hider proximity vignette settings (client-only toggles)
local hiderFadeDist = 120
local hiderFilterIntensity = 0.35
local disguiseMode = "replace"

-- Round identity (server-sent) + idempotency
local currentRoundId = nil

-- Disguise gating: only allow prop transform after hide phase ends / round starts
local allowDisguise = false
local disguisedThisRound = false
local disguisedRoundId = nil
local disguiseInProgress = false
local lastStateRequestAt = 0
local hideVisualTask = nil
local hideCameraTask = nil
local cameraLockEnabled = false
local originalCommandSetGameCamera = nil
local originalCoreCameraSetByName = nil
local originalCoreCameraSetCameraByName = nil

-- Forward declarations for network handlers
local onNetworkTaunt
local onGameStart
local onGameEnd
local onTimerUpdate
local onHidePhaseStart
local onHideTimerUpdate
local onHidePhaseEnd
local onRoundStart
local onRoundEnd
local onPlayerEliminated
local onAssignProp
local onChatMessage
local onHiderList
local onSeekerList
local onScanPulse
local spawnAndAttachProp
local preSpawnIfNeeded
local onTeamUpdate
local onSettings
local onTempPropClear
local cleanupTempSpawnSwapProps
local clearTempPropByServerString
local ensureVehicleExtensionsLoaded
local requestStateBurst

-- Forward declare helpers used by scan logic
local resolveOwnerPlayerIdFromVehId
local getNearestHiderDistance
local getNearestSeekerDistance
local closestHunterInfo = {}
local ffiAvailable = (ffi and ffi.C and ffi.C.BNG_DBG_DRAW_TextAdvanced)
local drawTextAdvanced = ffiAvailable and ffi.C.BNG_DBG_DRAW_TextAdvanced or nil
local hunterTagColor = color(255, 50, 50, 255)
local hunterTagBack = color(0, 0, 0, 150)
local hunterTagPos = vec3()

local PH_BUILD = "2026-02-11-phase2e"

local function onExtensionLoaded()
    print("DEBUG: PropHunt Core LOADED (" .. PH_BUILD .. ")")
    print(string.format("DEBUG: Modules util=%s audio=%s visuals=%s network=%s commands=%s disguise=%s proximity=%s",
        tostring(util.BUILD or "n/a"),
        tostring(audioFactory.BUILD or "n/a"),
        tostring(visuals.BUILD or "n/a"),
        tostring(networkMod.BUILD or "n/a"),
        tostring(commandMod.BUILD or "n/a"),
        tostring(disguiseMod.BUILD or "n/a"),
        tostring(proximityFactory.BUILD or "n/a")
    ))

    phAudio.initTauntFiles()
    print("DEBUG: PropHunt found " .. tostring(phAudio.getTauntCount()) .. " taunt sounds")

    -- Load taunt sound emitter helper (random taunt sounds)
    if extensions and extensions.load then
        local ok, err = pcall(function() extensions.load("soundEmitterControl") end)
        if ok and extensions.soundEmitterControl then
            phAudio.setEmitterReady(true)
        else
            print("DEBUG: soundEmitterControl failed to load: " .. tostring(err))
        end
    end


    -- Init (do NOT wipe mid-round; BeamMP clients can load late)
    allowDisguise = allowDisguise or false
    disguisedThisRound = disguisedThisRound or false
    disguisedRoundId = disguisedRoundId or nil
    disguiseInProgress = false
    currentRoundId = currentRoundId or nil
    assignedPropName = assignedPropName or nil
    lastStateRequestAt = 0

    -- Ensure helper postFX extensions are loaded
    if not extensions.vignetteShaderAPI then
        pcall(function() extensions.load("vignetteShaderAPI") end)
    end
    if not extensions.prophuntBlurAPI then
        pcall(function() extensions.load("prophuntBlurAPI") end)
    end

    -- Ensure PropHuntFlash extension is loaded
    if not extensions.PropHuntFlash then
        local ok, err = pcall(function() extensions.load("PropHuntFlash") end)
        if ok then
            print("DEBUG: PropHuntFlash extension loaded successfully")
        else
            print("ERROR: Failed to load PropHuntFlash: " .. tostring(err))
        end
    end

    local registered = networkMod.register({
        onNetworkTaunt = onNetworkTaunt,
        onGameStart = onGameStart,
        onGameEnd = onGameEnd,
        onTimerUpdate = onTimerUpdate,
        onHidePhaseStart = onHidePhaseStart,
        onHideTimerUpdate = onHideTimerUpdate,
        onHidePhaseEnd = onHidePhaseEnd,
        onRoundStart = onRoundStart,
        onRoundEnd = onRoundEnd,
        onPlayerEliminated = onPlayerEliminated,
        onAssignProp = onAssignProp,
        onChatMessage = onChatMessage,
        onHiderList = onHiderList,
        onSeekerList = onSeekerList,
        onScanPulse = onScanPulse,
        onTeamUpdate = onTeamUpdate,
        onSettings = onSettings,
        onTempPropClear = onTempPropClear,
    })

    -- Prime vehicle-side hooks even before a round starts.
    ensureVehicleExtensionsLoaded(false)

    if registered then
        requestStateBurst()
    end
end

-- --- AUDIO SYSTEM (modular) ---
local function playSound(filename, vehID, maxDistance, volumeOverride)
    phAudio.playSound(filename, vehID, maxDistance, volumeOverride)
end

-- --- SEEKER VISUAL BLOCK (modular) ---
local function setSeekerVisualBlock(state)
    visuals.setSeekerVisualBlock(state)
end

local function setProximityVignette(strength, intensity)
    visuals.setProximityVignette(strength, intensity)
end

local function strengthFromDistance(d, maxDist)
    return visuals.strengthFromDistance(d, maxDist or seekerFadeDist or 120)
end

local function drawHunterTag(info)
    if not info or not info.vid then return end
    local vehicle = be:getObjectByID(info.vid)
    if not vehicle then return end

    hunterTagPos:set(be:getObjectOOBBCenterXYZ(info.vid))

    local vehicleHeight = 0
    if not vehicle.vehicleHeight or vehicle.vehicleHeight == 0 then
        local veh = be:getObjectByID(info.vid)
        if veh and veh.getInitialHeight then
            vehicleHeight = veh:getInitialHeight() or 0
            vehicle.vehicleHeight = vehicleHeight
        end
    else
        vehicleHeight = vehicle.vehicleHeight
    end

    hunterTagPos.z = hunterTagPos.z + (vehicleHeight * 0.5) + 0.2

    if drawTextAdvanced then
        drawTextAdvanced(hunterTagPos.x, hunterTagPos.y, hunterTagPos.z, String(" Seeker "), hunterTagColor, true, false, hunterTagBack, false, false)
    end
end

local lastHunterNotifyPid = nil
local lastHunterNotifyTime = 0
local HUNTER_NOTICE_COOLDOWN = 1.0
local HUNTER_NOTICE_DISTANCE = 1e6 -- effectively unlimited
local function hunterNameForPid(pid)
    if not pid then return nil end
    if MP and MP.GetPlayers then
        local players = MP.GetPlayers()
        if players and players[pid] then
            return players[pid]
        end
    end
    if MPVehicleGE and MPVehicleGE.getVehicles then
        for _, veh in pairs(MPVehicleGE.getVehicles()) do
            local serverString = veh.serverVehicleString
            if serverString then
                local ownerPid = tonumber(string.match(serverString, "(%d+)%-%d+"))
                if ownerPid == pid then
                    return veh.ownerName
                end
            end
        end
    end
    return nil
end

proximity = proximityFactory.new({
    setRoundId = function(rid) currentRoundId = rid end,
    hunterNameForPid = hunterNameForPid
})

local function notifyNearestHunter()
    local info = closestHunterInfo
    if not info or not info.pid then return end
    if not info.dist or info.dist > HUNTER_NOTICE_DISTANCE then return end
    local now = os.clock()
    if lastHunterNotifyPid == info.pid and (now - lastHunterNotifyTime) < HUNTER_NOTICE_COOLDOWN then
        return
    end
    lastHunterNotifyPid = info.pid
    lastHunterNotifyTime = now
end

requestStateBurst = function()
    if not TriggerServerEvent then return end

    local function ping()
        pcall(function() TriggerServerEvent("PropHunt_clientReady", "") end)
        pcall(function() TriggerServerEvent("PropHunt_requestState", "") end)
    end

    ping()
    if scheduler and scheduler.add then
        local delays = {0.4, 1.0, 2.0, 4.0, 8.0}
        for _, delay in ipairs(delays) do
            local t = 0
            scheduler.add(function(dt)
                t = t + (dt or 0)
                if t >= delay then
                    ping()
                    return false
                end
                return true
            end)
        end
    end
end

ensureVehicleExtensionsLoaded = function(gameRunning)
    -- Force-load vehicle-side hooks on all currently spawned vehicles.
    -- This fixes cases where players must manually respawn/reload to participate.
    local runningStr = gameRunning and "true" or "false"
    local cmd = table.concat({
        "if extensions then",
        "  if not extensions.auto_prophunt then pcall(function() extensions.load('auto/prophunt') end) end",
        "  if not extensions.auto_prophuntcontactdetection then pcall(function() extensions.load('auto/prophuntcontactdetection') end) end",
        "  if not extensions.auto_tauntControl then pcall(function() extensions.load('auto/tauntControl') end) end",
        "  if extensions.auto_prophunt and extensions.auto_prophunt.setGameRunning then extensions.auto_prophunt.setGameRunning(" .. runningStr .. ") end",
        "end"
    }, " ")

    pcall(function() be:queueAllObjectLua(cmd) end)

    -- Retry passes to catch vehicles that spawn moments later.
    if scheduler and scheduler.add then
        local delays = {0.4, 1.0, 2.0}
        for _, delay in ipairs(delays) do
            local t = 0
            scheduler.add(function(dt)
                t = t + (dt or 0)
                if t >= delay then
                    pcall(function() be:queueAllObjectLua(cmd) end)
                    return false
                end
                return true
            end)
        end
    end
end

local function applyHideCameraLock(enable)
    if enable and not cameraLockEnabled then
        cameraLockEnabled = true
        if commands and commands.setGameCamera then
            originalCommandSetGameCamera = commands.setGameCamera
            commands.setGameCamera = function(name)
                if hidePhase and name ~= 'topDown' then return end
                originalCommandSetGameCamera(name)
            end
        end
        if core_camera and core_camera.setByName then
            originalCoreCameraSetByName = core_camera.setByName
            core_camera.setByName = function(name)
                if hidePhase and name ~= 'topDown' then return end
                originalCoreCameraSetByName(name)
            end
        end
        if core_camera and core_camera.setCameraByName then
            originalCoreCameraSetCameraByName = core_camera.setCameraByName
            core_camera.setCameraByName = function(name)
                if hidePhase and name ~= 'topDown' then return end
                originalCoreCameraSetCameraByName(name)
            end
        end
    elseif not enable and cameraLockEnabled then
        cameraLockEnabled = false
        if commands and commands.setGameCamera and originalCommandSetGameCamera then
            commands.setGameCamera = originalCommandSetGameCamera
            originalCommandSetGameCamera = nil
        end
        if core_camera and core_camera.setByName and originalCoreCameraSetByName then
            core_camera.setByName = originalCoreCameraSetByName
            originalCoreCameraSetByName = nil
        end
        if core_camera and core_camera.setCameraByName and originalCoreCameraSetCameraByName then
            core_camera.setCameraByName = originalCoreCameraSetCameraByName
            originalCoreCameraSetCameraByName = nil
        end
    end
end


-- --- RUNNER SET FUNCTION ---
local function setRunner()
    local veh = be:getPlayerVehicle(0)
    if not veh then return end

    runnerID = veh:getID()
    isHidden = false
    tauntTimer = 0

    beamMessage({
        msg = "PropHunt: Runner Set!",
        ttl = 2,
        icon = 'directions_car'
    })
end

-- --- PROP SET FUNCTION ---
local function setProp()
    local veh = be:getPlayerVehicle(0)
    if not veh then return end

    propID = veh:getID()

    beamMessage({
        msg = "PropHunt: Prop Set!",
        ttl = 2,
        icon = 'local_shipping'
    })
end

-- --- SWAP VEHICLES ---
local function performSwap()
    if not runnerID or not propID then
        beamMessage({
            msg = "Error: Set both vehicles first!",
            ttl = 3,
            icon = 'error'
        })
        return
    end

    local vRunner = be:getObjectByID(runnerID)
    local vProp = be:getObjectByID(propID)

    -- If either vehicle is missing, return silently like the old version
    if not vRunner or not vProp then
        print("DEBUG: One or both vehicles not found (IDs may have changed after reset)")
        beamMessage({
            msg = "Error: One or both vehicles not found. Please re-set them.",
            ttl = 3,
            icon = 'error'
        })
        return
    end

    -- swap positions
    local posRunner = vRunner:getPosition()
    local rotRunner = vRunner:getRotation()
    local posProp = vProp:getPosition()
    local rotProp = vProp:getRotation()

    vRunner:setPositionRotation(posProp.x,posProp.y,posProp.z,rotProp.x,rotProp.y,rotProp.z,rotProp.w)
    vProp:setPositionRotation(posRunner.x,posRunner.y,posRunner.z,rotRunner.x,rotRunner.y,rotRunner.z,rotRunner.w)

    vRunner:queueLuaCommand("obj:requestReset(RESET_PHYSICS)")
    vProp:queueLuaCommand("obj:requestReset(RESET_PHYSICS)")

    isHidden = not isHidden
    tauntTimer = TAUNT_INTERVAL

    if isHidden then
        be:enterVehicle(0, vProp)
    else
        be:enterVehicle(0, vRunner)
    end

    -- IMPORTANT: Update stored IDs after entering the vehicle
    -- The physics reset and vehicle enter may have changed the vehicle IDs
    -- We need to get the fresh IDs after all operations complete
    local finalVeh = be:getPlayerVehicle(0)
    if finalVeh then
        local finalID = finalVeh:getID()
        if isHidden then
            -- We're now in the prop, update prop ID
            propID = finalID
            print("DEBUG: Updated propID to " .. finalID .. " after swap")
        else
            -- We're now in the runner, update runner ID
            runnerID = finalID
            print("DEBUG: Updated runnerID to " .. finalID .. " after swap")
        end
    end
end

-- --- TAUNT ---
local function triggerTaunt()
    -- Prefer propID (when you're hidden), but allow taunting any time by falling back
    -- to the player's current vehicle.
    local veh = nil
    if propID then
        veh = be:getObjectByID(propID)
    end
    if not veh then
        veh = be:getPlayerVehicle(0)
    end
    if not veh then return end

    local vehId = veh:getID()

    -- Random taunt sound (vehicle-side tauntControl)
    veh:queueLuaCommand("if tauntControl then tauntControl.randomTaunt() end")

    -- Network broadcast (server now allows it any time)
    if MPCoreNetwork and MPCoreNetwork.isMPSession() and TriggerServerEvent then
        TriggerServerEvent("PropHunt_TauntRequest", tostring(vehId))
    end
end

local function manualTaunt()
    triggerTaunt()
    tauntTimer = TAUNT_INTERVAL
end

-- --- UPDATE LOOP ---
local function onUpdate(dt)
    -- UI flash overlay countdown
    if flashUiTimer > 0 then
        flashUiTimer = flashUiTimer - dt
        if flashUiTimer < 0 then flashUiTimer = 0 end
    end


    -- VEHICLE ID VALIDATION - Check if stored vehicle IDs are still valid after resets
    -- This handles the case where a vehicle is fully reset (destroyed and recreated with new ID)
    if runnerID or propID then
        local playerVeh = be:getPlayerVehicle(0)

        if playerVeh then
            local currentID = playerVeh:getID()

            -- Check if stored runner vehicle still exists
            if runnerID then
                local vRunner = be:getObjectByID(runnerID)
                if not vRunner then
                    -- Runner vehicle object no longer exists (was reset)
                    -- If we're currently in a vehicle that's not the prop ID, update runner
                    if currentID ~= propID then
                        print("DEBUG: Runner vehicle ID changed from " .. runnerID .. " to " .. currentID)
                        runnerID = currentID
                        beamMessage({
                            msg = "Runner vehicle auto-recovered",
                            ttl = 2,
                            icon = 'info'
                        })
                    end
                end
            end

            -- Check if stored prop vehicle still exists
            if propID then
                local vProp = be:getObjectByID(propID)
                if not vProp then
                    -- Prop vehicle object no longer exists (was reset)
                    -- If we're currently in a vehicle that's not the runner ID, update prop
                    if currentID ~= runnerID then
                        print("DEBUG: Prop vehicle ID changed from " .. propID .. " to " .. currentID)
                        propID = currentID
                        beamMessage({
                            msg = "Prop vehicle auto-recovered",
                            ttl = 2,
                            icon = 'info'
                        })
                    end
                end
            end
        end
    end

    if hidePhase and playerTeam == "hider" then
        preSpawnIfNeeded()
    end

    -- Hide-phase seeker freeze enforcement (fixes reset/unfreeze exploits)
    if hidePhase and playerTeam == "seeker" then
        local playerVeh = be:getPlayerVehicle(0)
        if playerVeh and core_vehicleBridge and core_vehicleBridge.executeAction then
            core_vehicleBridge.executeAction(playerVeh, 'setFreeze', true)
        end
        setSeekerVisualBlock(true)

        -- Re-apply topDown camera during hide phase (prevents reset/mode changes)
        pcall(function()
            if commands and commands.setGameCamera then
                commands.setGameCamera('topDown')
            elseif core_camera and core_camera.setByName then
                core_camera.setByName('topDown')
            end
        end)
    end

    -- Proximity vignette (Outbreak-style):
    -- - seekers see red vignette when close to a hider, hiders get the same cue when seekers are nearby
    if not hidePhase then
        local distance = nil
        local intensity = 0
        local maxRange = 0
        if gameActive and extensions and extensions.vignetteShaderAPI then
            if playerTeam == "seeker" and type(getNearestHiderDistance) == 'function' then
                distance = getNearestHiderDistance()
                maxRange = seekerFadeDist or 0
                intensity = seekerFilterIntensity or 0
            elseif playerTeam == "hider" and type(getNearestSeekerDistance) == 'function' then
                distance = getNearestSeekerDistance()
                maxRange = hiderFadeDist or 0
                intensity = hiderFilterIntensity or 0
                notifyNearestHunter()
            end
        end

        local strength = strengthFromDistance(distance, maxRange)
        setProximityVignette(strength, intensity)
    else
        setProximityVignette(0, 0)
    end

    -- AUTO TAUNT
    -- Keep nametags hidden for seeker throughout the round (some builds re-enable them)
    if gameActive and playerTeam == "seeker" and MPVehicleGE and MPVehicleGE.hideNicknames then
        MPVehicleGE.hideNicknames(true)
    end

    -- Auto-taunt disabled by default (it can sound like an auto horn).
    if AUTO_TAUNT_ENABLED and isHidden and propID then
        tauntTimer = tauntTimer - dt
        if tauntTimer <= 0 then
            triggerTaunt()
            tauntTimer = TAUNT_INTERVAL
        end

        -- Reset electrics a moment later so sound doesn't loop incorrectly
        if tauntTimer < (TAUNT_INTERVAL - 2) and tauntTimer > (TAUNT_INTERVAL - 2.2) then
            local veh = be:getObjectByID(propID)
            if veh then
                veh:queueLuaCommand("electrics.values.phTaunt = ''")
            end
        end
    end

    -- UPDATE ACTIVE SOUND EMITTERS
    phAudio.updateEmitters(dt)

    -- Disguise is handled via replaceVehicle props.

    -- UPDATE UI
    uiTimer = uiTimer + dt
    if uiTimer > 0.1 then
        uiTimer = 0
        guihooks.trigger('PropHuntUpdate',{
            isHidden = isHidden,
            timer = tauntTimer,
            runnerSet = (runnerID ~= nil),
            propSet = (propID ~= nil),
            gameActive = gameActive,
            gameTimer = gameTimer,
            playerTeam = playerTeam,
            hidePhase = hidePhase,
            hideTimer = hideTimer,
            flashActive = (flashUiTimer > 0),
            flashAlpha = math.min(1, flashUiTimer / 0.6)
        })
    end
end



-- --- NETWORK HANDLERS (Taunt + Flash sound) ---
onNetworkTaunt = function(data)
    local vehID = tonumber(data)
    if not vehID then return end

    -- Don't double-taunt the owner
    local playerVeh = be:getPlayerVehicle(0)
    if playerVeh and playerVeh:getID() == vehID then return end

    -- Play taunt for remote players
    local selectedSound = phAudio.getRandomTauntSound()
    if not selectedSound then return end
    playSound(selectedSound, vehID)
end

-- NOTE: Network handlers are now registered in onExtensionLoaded() above

-- --- GAME STATE HANDLERS ---

local function formatMMSS(total)
    total = math.max(0, tonumber(total) or 0)
    local m = math.floor(total / 60)
    local s = math.floor(total % 60)
    return string.format("%d:%02d", m, s)
end

local function showRoundHud(text)
    -- Outbreak-style HUD message (1s TTL).
    -- Use a built-in category key so the UI doesn't spam its console trying to derive an icon.
    if guihooks and guihooks.message then
        guihooks.message({txt = text}, 1, "info")
    end
end

local function resetRoundState(roundId)
    if roundId then
        currentRoundId = roundId
    end
    gameActive = false
    gameTimer = 0
    lastGameTimer = 0
    hidePhase = false
    hideTimer = 0
    allowDisguise = false
    disguisedThisRound = false
    disguisedRoundId = nil
    disguiseInProgress = false
    lastStateRequestAt = 0
    propStateRequestedRound = nil
end

local function logCommandUsage(cmd, details)
    local detailStr = (details and details ~= "") and (" [" .. details .. "]") or ""
    print(string.format("[PH CMD] %s team=%s active=%s round=%s%s",
        tostring(cmd), tostring(playerTeam or "none"), tostring(gameActive), tostring(currentRoundId), detailStr))
end

local clientSettingKeyMap = {
    tauntdist = "taunt_dist",
    taunt_dist = "taunt_dist",
    proximity = "proximity",
    proximityintensity = "proximity",
    proximityfilter = "proximity",
    proximity_dist = "proximity_dist",
    proximitydist = "proximity_dist",
    proximitydistance = "proximity_dist",
    hiderfadedist = "hider_fade",
    hiderfadedistance = "hider_fade",
    hiderfilterintensity = "hider_intensity",
    hiderfilter = "hider_intensity",
    hiderproximity = "hider_intensity",
    hiderproximitydist = "hider_fade",
    hiderproximitydistance = "hider_fade"
}

local function getClientSettingKey(name)
    if not name then return nil end
    local normalized = name:lower():gsub("[^%w]", "")
    return clientSettingKeyMap[normalized]
end

onGameStart = function(data)
    -- data: "roundId,team" (or legacy "team")
    local roundStr, team = tostring(data or ""):match("^%s*(%d+)%s*,%s*(%w+)%s*$")
    local roundId = roundStr and tonumber(roundStr)

    if roundId and lastHandledGameStartRound == roundId then
        print("[PH] Duplicate GameStart ignored for round " .. tostring(roundId))
        return
    end
    lastHandledGameStartRound = roundId

    resetRoundState(roundId)

    if not team then
        team = tostring(data or "")
    end

    playerTeam = team
    gameActive = true
    gameTimer = 300
    lastGameTimer = 300 -- reset timer tracking

    -- Ensure vehicle-side hooks are loaded, then start collision checks.
    ensureVehicleExtensionsLoaded(true)

    if team == "seeker" then
        -- Hide nametags for seekers only (apply immediately + delayed to beat BeamMP UI refresh)
        if MPVehicleGE and MPVehicleGE.hideNicknames then
            MPVehicleGE.hideNicknames(true)
            if scheduler and scheduler.add then
                local t = 0
                scheduler.add(function(dt)
                    t = t + dt
                    if t > 1.0 then
                        MPVehicleGE.hideNicknames(true)
                        return false
                    end
                    return true
                end)
            end
        end

        beamMessage({
            msg = "You are a SEEKER! Find and tag the hiders!",
            ttl = 5,
            icon = 'visibility'
        })
        print("DEBUG: You are a SEEKER")
    else
        -- Ensure hiders can still see nametags
        if MPVehicleGE and MPVehicleGE.hideNicknames then
            MPVehicleGE.hideNicknames(false)
        end

        beamMessage({
            msg = "You are a HIDER! Hide and survive for 5 minutes!",
            ttl = 5,
            icon = 'visibility_off'
        })
        print("DEBUG: You are a HIDER")

        -- E) Do NOT disguise on game start.
        -- We wait until hide phase ends so hiders can drive to a hiding spot first.
        -- (Disguise will be applied in onHidePhaseEnd.)
    end
end

onGameEnd = function(data)
    -- data may contain a reason/winner string from server (timeout/seekers/manual/etc)
    local reason = tostring(data or "")

    playerTeam = nil
    gameActive = false
    disguisedThisRound = false
    disguisedRoundId = nil
    gameTimer = 0
    lastGameTimer = 0 -- reset timer tracking
    hidePhase = false
    hideTimer = 0
    allowDisguise = false

    setSeekerVisualBlock(false)

    -- Best-effort: restore a normal camera at end
    pcall(function()
        if commands and commands.setGameCamera then
            commands.setGameCamera('orbit')
        elseif core_camera and core_camera.setByName then
            core_camera.setByName('orbit')
        end
    end)

    -- Restore nametags
    if MPVehicleGE and MPVehicleGE.hideNicknames then
        MPVehicleGE.hideNicknames(false)
    end

    -- Stop vehicle-side collision checks.
    ensureVehicleExtensionsLoaded(false)

    if disguiseMode == "spawnswap" then
        cleanupTempSpawnSwapProps()
    end

    local msg = "Game Over!"
    if reason ~= "" then
        if reason == "timeout" or reason == "hiders" then
            msg = "Round Over: Hiders win!"
        elseif reason == "seekers" then
            msg = "Round Over: Seekers win!"
        elseif reason == "manual" then
            msg = "Round Over: Stopped"
        else
            msg = "Round Over: " .. reason
        end
    end

    beamMessage({
        msg = msg,
        ttl = 4,
        icon = 'flag'
    })
    print("DEBUG: Game ended (" .. reason .. ")")
end

onTimerUpdate = function(data)
    local roundStr, secStr = tostring(data or ""):match("^%s*(%d+)%s*,%s*(%d+)%s*$")
    if roundStr then currentRoundId = tonumber(roundStr) end
    local newTimer = tonumber(secStr) or tonumber(data) or 0
    showRoundHud("TIME LEFT: " .. formatMMSS(newTimer))

    -- Check for timer milestones and show notifications (only during main round, not hide phase)
    if gameActive and not hidePhase then
        -- Minute updates
        if lastGameTimer > 60 and newTimer <= 60 then
            beamMessage({
                msg = "1 minute remaining!",
                ttl = 3,
                icon = 'timer'
            })
        end

        -- 30 seconds remaining
        if lastGameTimer > 30 and newTimer <= 30 then
            beamMessage({
                msg = "30 seconds remaining!",
                ttl = 3,
                icon = 'warning'
            })
        end

        -- Final countdown (10, 9, 8, 7, 6, 5, 4, 3, 2, 1)
        if newTimer >= 1 and newTimer <= 10 and lastGameTimer > newTimer then
            beamMessage({
                msg = tostring(newTimer),
                ttl = 1,
                icon = 'timer'
            })
        end
    end

    lastGameTimer = gameTimer
    gameTimer = newTimer
end

-- =============================
-- HIDER DISGUISE (BeamNG props)
-- =============================
-- Best-effort vehicle ids used by elimination/end-round revert paths.
local originalVehId = nil
local propVehId = nil

spawnAndAttachProp = function(propName)
    disguiseMod.spawnAndAttachProp({
        beamMessage = beamMessage,
        isDisguiseInProgress = function() return disguiseInProgress end,
        setDisguiseInProgress = function(v) disguiseInProgress = v end,
        isDisguised = function() return disguisedThisRound end,
        isAlreadyDisguisedThisRound = function()
            return currentRoundId and disguisedRoundId == currentRoundId
        end,
        setDisguised = function(v)
            disguisedThisRound = v and true or false
            if disguisedThisRound then
                disguisedRoundId = currentRoundId
            end
        end,
        setPropStateRequestedRound = function(v)
            propStateRequestedRound = v
        end,
        getDisguiseMode = function() return disguiseMode end,
        getPlayerTeam = function() return playerTeam end,
        getOriginalVehId = function() return originalVehId end,
        setOriginalVehId = function(v) originalVehId = v end,
        getPropVehId = function() return propVehId end,
        setPropVehId = function(v) propVehId = v end,
    }, propName)
end

preSpawnIfNeeded = function()
    if playerTeam ~= "hider" then return end
    if not assignedPropName or assignedPropName == "" then return end
    disguiseMod.preSpawnProp({
        getDisguiseMode = function() return disguiseMode end,
        getPlayerTeam = function() return playerTeam end,
        getPropVehId = function() return propVehId end,
        setPropVehId = function(v) propVehId = v end,
        setOriginalVehId = function(v) originalVehId = v end,
    }, assignedPropName)
end

-- Hide phase handlers
onHidePhaseStart = function(data)
    -- data: "roundId,seconds" (new) or just seconds
    local roundStr, secStr = tostring(data or ""):match("^%s*(%d+)%s*,%s*(%d+)%s*$")
    if roundStr then currentRoundId = tonumber(roundStr) end
    local secs = tonumber(secStr) or tonumber(data) or 20

    hidePhase = true
    local roundId = roundStr and tonumber(roundStr) or currentRoundId
    if roundId and lastHandledHidePhaseStartRound == roundId then
        print("[PH] Duplicate hide-phase-start ignored for round " .. tostring(roundId))
        return
    end
    lastHandledHidePhaseStartRound = roundId

    hideTimer = secs
    allowDisguise = false
    preSpawnIfNeeded()

    -- If we missed early AssignProp (late-loaded), request current state again.
    if playerTeam == "hider" and (not assignedPropName or assignedPropName == "") and TriggerServerEvent then
        local t = os.clock()
        if (t - lastStateRequestAt) > 1.0 then
            lastStateRequestAt = t
            TriggerServerEvent("PropHunt_requestState", "")
        end
    end

    -- Freeze seeker's vehicle during hide phase
    if playerTeam == "seeker" then
        local playerVeh = be:getPlayerVehicle(0)
        if playerVeh then
            core_vehicleBridge.executeAction(playerVeh, 'setFreeze', true)
            print("DEBUG: Seeker vehicle frozen during hide phase")
        end

        setSeekerVisualBlock(true)
        applyHideCameraLock(true)
        if scheduler and scheduler.add then
            if hideVisualTask then hideVisualTask = nil end
            hideVisualTask = scheduler.add(function(dt)
                setSeekerVisualBlock(true)
                if not hidePhase then
                    hideVisualTask = nil
                    return false
                end
                return true
            end)
            if hideCameraTask then hideCameraTask = nil end
            hideCameraTask = scheduler.add(function(dt)
                if commands and commands.setGameCamera then
                    commands.setGameCamera('topDown')
                end
                if core_camera and core_camera.setByName then
                    core_camera.setByName('topDown')
                end
                if core_camera and core_camera.setCameraByName then
                    core_camera.setCameraByName('topDown')
                end
                if not hidePhase then
                    hideCameraTask = nil
                    return false
                end
                return true
            end)
        else
            pcall(function()
                if commands and commands.setGameCamera then
                    commands.setGameCamera('topDown')
                end
                if core_camera and core_camera.setByName then
                    core_camera.setByName('topDown')
                end
            end)
        end

        beamMessage({
            msg = "Wait " .. hideTimer .. " seconds while hiders hide...",
            ttl = 3,
            icon = 'block'
        })
    else
        beamMessage({
            msg = "Hide phase! " .. hideTimer .. " seconds to hide!",
            ttl = 3,
            icon = 'visibility_off'
        })
    end

    print("DEBUG: Hide phase started - " .. hideTimer .. " seconds")
end

onHideTimerUpdate = function(data)
    local roundStr, secStr = tostring(data or ""):match("^%s*(%d+)%s*,%s*(%d+)%s*$")
    if roundStr then currentRoundId = tonumber(roundStr) end
    hideTimer = tonumber(secStr) or tonumber(data) or 0
    showRoundHud("HIDE: " .. tostring(hideTimer) .. "s")
end

onHidePhaseEnd = function(data)
    local roundStr = tostring(data or ""):match("^%s*(%d+)%s*$")
    if roundStr then currentRoundId = tonumber(roundStr) end

    hidePhase = false
    local roundId = roundStr and tonumber(roundStr) or currentRoundId
    if roundId and lastHandledHidePhaseEndRound == roundId then
        print("[PH] Duplicate hide-phase-end ignored for round " .. tostring(roundId))
        return
    end
    lastHandledHidePhaseEndRound = roundId

    hideTimer = 0
    allowDisguise = true

    print("DEBUG: onHidePhaseEnd assignedProp=" .. tostring(assignedPropName) .. " allow=" .. tostring(allowDisguise) .. " round=" .. tostring(currentRoundId))

    -- Unfreeze seeker's vehicle when hide phase ends
    if playerTeam == "seeker" then
        local playerVeh = be:getPlayerVehicle(0)
        if playerVeh then
            core_vehicleBridge.executeAction(playerVeh, 'setFreeze', false)
            print("DEBUG: Seeker vehicle unfrozen - hunt begins!")
        end

        setSeekerVisualBlock(false)
        applyHideCameraLock(false)
        if hideVisualTask then
            hideVisualTask = nil
        end
        if hideCameraTask then
            hideCameraTask = nil
        end

        -- Return camera to orbit when round starts (nice default)
        pcall(function()
            if commands and commands.setGameCamera then
                commands.setGameCamera('orbit')
            elseif core_camera and core_camera.setByName then
                core_camera.setByName('orbit')
            end
        end)

        beamMessage({
            msg = "Hunt begins NOW!",
            ttl = 3,
            icon = 'visibility'
        })
    else
        -- Hiders: now transform into prop
        if assignedPropName and assignedPropName ~= "" then
            spawnAndAttachProp(assignedPropName)
        else
            local roundId = currentRoundId or tonumber(roundStr)
            if TriggerServerEvent and roundId and propStateRequestedRound ~= roundId then
                propStateRequestedRound = roundId
                print("[PH] Requesting prop state for round " .. tostring(roundId))
                TriggerServerEvent("PropHunt_requestState", "")
            end
        end

        beamMessage({
            msg = "Hide phase over! You're now a prop.",
            ttl = 3,
            icon = 'warning'
        })
    end
    print("DEBUG: Hide phase ended")
end

onRoundStart = function(data)
    local roundStr = tostring(data or ""):match("^%s*(%d+)%s*$")
    if roundStr then currentRoundId = tonumber(roundStr) end

    allowDisguise = true
    print("DEBUG: Main round started")

    -- Late-load / missed hide-phase end: if we already have an assigned prop, apply now.
    if playerTeam == "hider" and assignedPropName and assignedPropName ~= "" then
        spawnAndAttachProp(assignedPropName)
        disguisedRoundId = currentRoundId
    end
end

onPlayerEliminated = function(data)
    -- data can be "<playerId>" or "<playerId>,<playerName>"
    local pidStr, nameStr = tostring(data or ""):match("^%s*(%d+)%s*,?%s*(.*)$")
    local targetId = tonumber(pidStr)
    if not targetId then return end

    local label = (nameStr and nameStr ~= "") and nameStr or ("Player " .. tostring(targetId))

    beamMessage({
        msg = label .. " eliminated",
        ttl = 3,
        icon = 'close'
    })

    -- If it's us, revert back to our pre-disguise vehicle (best-effort)
    if MPVehicleGE and MPVehicleGE.getServerVehicleID then
        local myVehId = be:getPlayerVehicleID(0)
        local myServerVeh = myVehId and MPVehicleGE.getServerVehicleID(myVehId)
        if myServerVeh then
            local myPid = tonumber(string.match(tostring(myServerVeh), "(%d+)%-%d+"))
            if myPid and myPid == targetId then
                -- If original vehicle is known, switch back into it.
                if originalVehId and be:getObjectByID(originalVehId) then
                    local origVeh = be:getObjectByID(originalVehId)
                    local curVeh = be:getPlayerVehicle(0)
                    local curPos = curVeh and curVeh.getPosition and curVeh:getPosition() or nil
                    local curRot = curVeh and curVeh.getRotation and curVeh:getRotation() or nil

                    pcall(function() origVeh:setActive(1) end)
                    if curPos and curRot and origVeh.setPositionRotation then
                        local ox, oy = 3.0, 0.0
                        if curVeh and curVeh.getDirectionVector then
                            local okDir, dir = pcall(function() return curVeh:getDirectionVector() end)
                            if okDir and dir then
                                -- place restored car ~2m to the side to avoid overlap with seeker vehicle
                                ox = -((dir.y or 0) * 3.0)
                                oy =  ((dir.x or 0) * 3.0)
                            end
                        end
                        pcall(function()
                            origVeh:setPositionRotation(curPos.x + ox, curPos.y + oy, curPos.z, curRot.x, curRot.y, curRot.z, curRot.w)
                        end)
                    end
                    pcall(function() origVeh:queueLuaCommand('obj:setGhostEnabled(false)') end)
                    pcall(function() origVeh:setMeshAlpha(10000, "", false) end)
                    pcall(function() origVeh:queueLuaCommand('electrics.setIgnitionLevel(3)') end)
                    pcall(function()
                        if core_vehicleBridge and core_vehicleBridge.executeAction then
                            core_vehicleBridge.executeAction(origVeh, 'setFreeze', false)
                        end
                    end)
                    be:enterVehicle(0, origVeh)

                    -- Hide/deactivate prop vehicle after elimination (optional)
                    if propVehId then
                        local pv = be:getObjectByID(propVehId)
                        if pv then
                            pcall(function() pv:setActive(0) end)
                            pcall(function()
                                if core_vehicleBridge and core_vehicleBridge.executeAction then
                                    core_vehicleBridge.executeAction(pv, 'setFreeze', true)
                                end
                            end)
                        end
                    end

                    if disguiseMode == "spawnswap" and cleanupTempSpawnSwapProps then
                        cleanupTempSpawnSwapProps()
                    end

                    beamMessage({ msg = "You were found! Back to your car (eliminated).", ttl = 4, icon = 'directions_car' })

                else
                    -- With spawn+deactivate disguises, we should always be able to go back to the original vehicle.
                    print("WARN: No original vehicle captured; cannot revert")
                end
            end
        end
    end
end

onRoundEnd = function(data)
    -- data can contain a reason string from the server
    local reason = tostring(data or "")

    -- Best-effort: restore original vehicle for hiders (spawn+deactivate disguise)
    if originalVehId and be:getObjectByID(originalVehId) then
        local ov = be:getObjectByID(originalVehId)
        local curVeh = be:getPlayerVehicle(0)
        local curPos = curVeh and curVeh.getPosition and curVeh:getPosition() or nil
        local curRot = curVeh and curVeh.getRotation and curVeh:getRotation() or nil

        pcall(function() ov:setActive(1) end)
        if curPos and curRot and ov.setPositionRotation then
            local ox, oy = 3.0, 0.0
            if curVeh and curVeh.getDirectionVector then
                local okDir, dir = pcall(function() return curVeh:getDirectionVector() end)
                if okDir and dir then
                    ox = -((dir.y or 0) * 3.0)
                    oy =  ((dir.x or 0) * 3.0)
                end
            end
            pcall(function()
                ov:setPositionRotation(curPos.x + ox, curPos.y + oy, curPos.z, curRot.x, curRot.y, curRot.z, curRot.w)
            end)
        end
        pcall(function() ov:queueLuaCommand('obj:setGhostEnabled(false)') end)
        pcall(function() ov:setMeshAlpha(10000, "", false) end)
        pcall(function() ov:queueLuaCommand('electrics.setIgnitionLevel(3)') end)
        pcall(function()
            if core_vehicleBridge and core_vehicleBridge.executeAction then
                core_vehicleBridge.executeAction(ov, 'setFreeze', false)
            end
        end)
        pcall(function() be:enterVehicle(0, ov) end)
    end
    if propVehId and be:getObjectByID(propVehId) then
        local pv = be:getObjectByID(propVehId)
        pcall(function() pv:setActive(0) end)
        pcall(function()
            if core_vehicleBridge and core_vehicleBridge.executeAction then
                core_vehicleBridge.executeAction(pv, 'setFreeze', true)
            end
        end)
    end

    -- Play end sound for all players (louder)
    local playerVeh = be:getPlayerVehicle(0)
    if playerVeh then
        local vehID = playerVeh:getID()
        local endSound = "art/Sounds/Taunts/end.ogg"
        playSound(endSound, vehID, 999999, 2.5) -- boost volume
    end

    local msg = "END OF ROUND!"
    if reason ~= "" then
        msg = "END OF ROUND (" .. reason .. ")"
    end

    beamMessage({
        msg = msg,
        ttl = 5,
        icon = 'flag'
    })
    print("DEBUG: Round ended: " .. reason)
    if disguiseMode == "spawnswap" then
        cleanupTempSpawnSwapProps()
    end

    assignedPropName = nil
    originalVehId = nil
    propVehId = nil
end

-- --- CHAT COMMANDS ---
onChatMessage = function(msg)
    commandMod.handleChatMessage(msg, {
        beamMessage = beamMessage,
        getClientSettingKey = getClientSettingKey,
        logCommandUsage = logCommandUsage,

        setTauntDistance = function(v)
            TAUNT_SOUND_DISTANCE = v
            phAudio.tauntDistance = v
        end,
        getTauntDistance = function() return TAUNT_SOUND_DISTANCE end,

        setSeekerFilterIntensity = function(v) seekerFilterIntensity = v end,
        getSeekerFilterIntensity = function() return seekerFilterIntensity end,

        setSeekerFadeDist = function(v) seekerFadeDist = v end,
        getSeekerFadeDist = function() return seekerFadeDist end,

        setHiderFadeDist = function(v) hiderFadeDist = v end,
        getHiderFadeDist = function() return hiderFadeDist end,

        setHiderFilterIntensity = function(v) hiderFilterIntensity = v end,
        getHiderFilterIntensity = function() return hiderFilterIntensity end,
    })
end

-- =============================
-- TEAM LISTS (for proximity + scans)
-- =============================
onSeekerList = function(data)
    if proximity and proximity.onSeekerList then
        proximity.onSeekerList(data)
    end
end

-- =============================
-- SEEKER SCAN (client-side strength)
-- =============================
getNearestHiderDistance = function()
    if proximity and proximity.getNearestHiderDistance then
        return proximity.getNearestHiderDistance()
    end
    return nil
end

getNearestSeekerDistance = function()
    if proximity and proximity.getNearestSeekerDistance then
        local best, info = proximity.getNearestSeekerDistance()
        closestHunterInfo = info or {}
        return best
    end
    closestHunterInfo = {}
    return nil
end

local function playScannerBeep(strength)
    local veh = be:getPlayerVehicle(0)
    if not veh then return end
    local vehID = veh:getID()

    local snd = "art/Sounds/Taunts/ping.wav"

    local beeps = 3
    local minGap = 0.12
    local maxGap = 0.85
    local gap = maxGap - (maxGap - minGap) * (strength or 0)

    local vol = 0.35 + 0.65 * (strength or 0)

    if scheduler and scheduler.add then
        local elapsed = 0
        local nextBeepAt = 0
        local i = 0

        scheduler.add(function(dt)
            elapsed = elapsed + (dt or 0)

            if elapsed >= nextBeepAt then
                playSound(snd, vehID, 12, vol)
                i = i + 1
                nextBeepAt = elapsed + gap
            end

            return i < beeps
        end)
    else
        playSound(snd, vehID, 12, vol)
    end
end

onHiderList = function(data)
    if proximity and proximity.onHiderList then
        proximity.onHiderList(data)
    end
end

onScanPulse = function(data)
    -- data: roundId
    if playerTeam ~= "seeker" then return end
    if not gameActive or hidePhase then return end

    local rid = tonumber(data)
    if rid then currentRoundId = rid end

    local d = getNearestHiderDistance()
    local s = strengthFromDistance(d)

    if d then
        beamMessage({ msg = string.format("SCAN: signal %.0f%%", s * 100), ttl = 1.5, icon = 'radar' })
    else
        beamMessage({ msg = "SCAN: no signal", ttl = 1.5, icon = 'radar' })
    end

    playScannerBeep(s)
end

onSettings = function(data)
    -- data: "roundId,seekerFadeDist,seekerFilterIntensity,hiderFadeDist,hiderFilterIntensity,disguiseMode"
    local parts = {}
    for part in string.gmatch(tostring(data or ""), "[^,]+") do
        table.insert(parts, part)
    end

    if #parts >= 1 then
        local rid = tonumber(parts[1])
        if rid then currentRoundId = rid end
    end

    if #parts >= 2 then
        local v = tonumber(parts[2])
        if v then seekerFadeDist = v end
    end

    if #parts >= 3 then
        local v = tonumber(parts[3])
        if v then seekerFilterIntensity = v end
    end

    if #parts >= 4 then
        local v = tonumber(parts[4])
        if v then hiderFadeDist = v end
    end

    if #parts >= 5 then
        local v = tonumber(parts[5])
        if v then hiderFilterIntensity = v end
    end

    if #parts >= 6 then
        local d = tostring(parts[6] or ""):lower()
        if d == "replace" or d == "preload" or d == "spawnswap" then
            disguiseMode = d
        end
    end

    preSpawnIfNeeded()
end

clearTempPropByServerString = function(targetServerVeh)
    if not targetServerVeh or targetServerVeh == "" then return end

    -- 1) Best-effort remove from BeamMP vehicle registry (prevents stale nametags)
    if MPVehicleGE and MPVehicleGE.onServerVehicleRemoved then
        pcall(function() MPVehicleGE.onServerVehicleRemoved(targetServerVeh) end)
    end

    -- 2) Also sweep any matching local object and hide/deactivate it
    if MPVehicleGE and MPVehicleGE.getVehicles then
        local list = MPVehicleGE.getVehicles() or {}
        for k, veh in pairs(list) do
            if tostring(veh.serverVehicleString or "") == targetServerVeh then
                local obj = be:getObjectByID(veh.gameVehicleID)
                if obj then
                    pcall(function() obj:queueLuaCommand('obj:setGhostEnabled(true)') end)
                    pcall(function() obj:setMeshAlpha(0, "", false) end)
                    pcall(function() obj:setActive(0) end)
                    pcall(function()
                        if core_vehicleBridge and core_vehicleBridge.executeAction then
                            core_vehicleBridge.executeAction(obj, 'setFreeze', true)
                        end
                    end)
                end

                -- kill potential label source in MPVehicleGE cache
                veh.ownerName = ""
                veh.nickname = ""
                list[k] = nil
            end
        end
    end
end

onTempPropClear = function(data)
    local targetServerVeh = tostring(data or "")
    if targetServerVeh == "" then return end
    clearTempPropByServerString(targetServerVeh)
end

onTeamUpdate = function(data)
    -- data: "roundId,team"
    local roundStr, team = tostring(data or ""):match("^%s*(%d+)%s*,%s*(%w+)%s*$")
    if roundStr then currentRoundId = tonumber(roundStr) end
    if team and team ~= "" then
        playerTeam = team
        if team == "seeker" then
            -- Ensure nametags stay hidden when you convert
            if MPVehicleGE and MPVehicleGE.hideNicknames then
                MPVehicleGE.hideNicknames(true)
            end
            beamMessage({ msg = "You have been CONVERTED into a SEEKER!", ttl = 4, icon = 'visibility' })
        else
            beamMessage({ msg = "Team updated: " .. tostring(team), ttl = 3, icon = 'info' })
        end
    end
end

cleanupTempSpawnSwapProps = function()
    local function doSweep()
        if not MPVehicleGE or not MPVehicleGE.getVehicles then return end

        for _, veh in pairs(MPVehicleGE.getVehicles() or {}) do
            local svs = tostring(veh.serverVehicleString or "")
            local _, idx = string.match(svs, "^(%d+)%-(%d+)$")
            idx = tonumber(idx)
            if idx and idx > 0 then
                clearTempPropByServerString(svs)
            end
        end
    end

    -- Immediate + delayed passes catch late-spawned MP vehicles on remote clients.
    doSweep()
    if scheduler and scheduler.add then
        local delays = {0.5, 1.0, 2.0}
        for _, delay in ipairs(delays) do
            local t = 0
            scheduler.add(function(dt)
                t = t + (dt or 0)
                if t >= delay then
                    doSweep()
                    return false
                end
                return true
            end)
        end
    end
end

local function manualScan()
    if playerTeam ~= "seeker" then
        beamMessage({ msg = "Scan is seekers-only", ttl = 2, icon = 'info' })
        return
    end
    if not gameActive or hidePhase then
        beamMessage({ msg = "Can't scan yet", ttl = 2, icon = 'timer' })
        return
    end

    if TriggerServerEvent then
        TriggerServerEvent("PropHunt_ScanRequest", "")
        beamMessage({ msg = "SCAN: ping...", ttl = 1.0, icon = 'radar' })
    end
end

-- --- EXPORTS ---
M.onExtensionLoaded = onExtensionLoaded
M.onUpdate = onUpdate
M.onVehicleSwitched = function(oldId, newId)
    -- Keep hooks attached if player changes/reloads vehicle mid-session.
    ensureVehicleExtensionsLoaded(gameActive)
    requestStateBurst()
end
M.onPreRender = function(dt)
    if playerTeam == "hider" and not hidePhase and closestHunterInfo and closestHunterInfo.dist and closestHunterInfo.dist < HUNTER_NOTICE_DISTANCE then
        drawHunterTag(closestHunterInfo)
    end
end
M.onChatMessage = onChatMessage
M.setRunner = setRunner
M.setProp = setProp
M.performSwap = performSwap
M.manualTaunt = manualTaunt
M.manualScan = manualScan
M.playSound = playSound
M.getPropID = function() return propID end


-- =============================
-- COLLISION TAGGING (Seeker)
-- =============================
resolveOwnerPlayerIdFromVehId = function(vehId)
    if proximity and proximity.resolveOwnerPlayerIdFromVehId then
        return proximity.resolveOwnerPlayerIdFromVehId(vehId)
    end
    return nil
end

local lastAutoTagTime = 0
local AUTO_TAG_COOLDOWN = 0.5

local function onSeekerCollision(otherVehId)
    if not gameActive or hidePhase then return end
    if playerTeam ~= "seeker" then return end

    local t = os.clock()
    if (t - lastAutoTagTime) < AUTO_TAG_COOLDOWN then return end
    lastAutoTagTime = t

    local otherId = tonumber(otherVehId)
    if not otherId then return end

    -- Prefer the more accurate OBB overlap gate (game-style hitbox) if available
    local myVeh = be:getPlayerVehicle(0)
    local myId = myVeh and myVeh:getID() or nil

    if M.sendTagContact and myId then
        M.sendTagContact(otherId, myId)
        return
    end

    -- Fallback: old behavior (owner resolution only)
    local targetPlayerId = resolveOwnerPlayerIdFromVehId(otherId)
    if not targetPlayerId then
        print("DEBUG: Could not resolve owner for collided vehicle " .. tostring(otherId) .. " (BeamMP API mismatch)")
        return
    end

    if TriggerServerEvent then
        TriggerServerEvent("PropHunt_onContactReceive", tostring(targetPlayerId))
        print("DEBUG: Auto-tag collision => contact on player " .. tostring(targetPlayerId))
    end
end


onAssignProp = function(data)
    -- data: "roundId,propKey" (new) or just propKey
    local roundStr, propKey = tostring(data or ""):match("^%s*(%d+)%s*,%s*([^,]+)%s*$")
    if propKey then
        assignedPropName = tostring(propKey)
        currentRoundId = tonumber(roundStr) or currentRoundId
    else
        assignedPropName = tostring(data or "")
    end

    if assignedPropName == "" then return end

    beamMessage({ msg = "Prop assigned: " .. assignedPropName, ttl = 4, icon = 'local_shipping' })

    preSpawnIfNeeded()

    -- Apply at most once per round
    if currentRoundId and disguisedRoundId == currentRoundId then
        return
    end

    if allowDisguise and playerTeam == "hider" then
        spawnAndAttachProp(assignedPropName)
        disguisedRoundId = currentRoundId
    else
        print("DEBUG: Prop assigned; will disguise at hide-phase end (allowDisguise=" .. tostring(allowDisguise) .. ", team=" .. tostring(playerTeam) .. ")")
    end
end

-- Export a callable so we can trigger from UI/keybind later if desired
M.onSeekerCollision = onSeekerCollision


-- =============================
-- SEEKER TAGGING (Outbreak-style collision contact)
-- =============================
local lastTagContact = 0
local TAG_CONTACT_COOLDOWN = 0.25

-- Debug + hard-enable OBB gating for tag validation
local TAG_OBB_ENABLED = true
local TAG_OBB_DEBUG = true   -- set false once confirmed
local lastObbDebugAt = 0

local function sendTagContact(remoteVehID, localVehID)
    if not gameActive or hidePhase then return end
    if playerTeam ~= "seeker" then return end

    local t = os.clock()
    if (t - lastTagContact) < TAG_CONTACT_COOLDOWN then return end
    lastTagContact = t

    -- In some BeamMP builds, isOwn(gameVehId) can be unreliable when multiple seekers are present.
    -- Do NOT hard-block here; the server will still validate the sender is a seeker.
    -- (We keep the check only for optional debug.)
    -- if MPVehicleGE and MPVehicleGE.isOwn and not MPVehicleGE.isOwn(localVehID) then return end

    -- Extra validation: use true vehicle world OBB overlap (game code approach)
    if TAG_OBB_ENABLED then
        local function getOOBB(vehId)
            if not vehId then return nil, "no vehId" end
            if not be or not be.getObjectByID then return nil, "no be:getObjectByID" end
            local veh = be:getObjectByID(vehId)
            if not veh then return nil, "no veh object" end
            if not veh.getSpawnWorldOOBB then return nil, "no getSpawnWorldOOBB method" end
            local ok, bb = pcall(function() return veh:getSpawnWorldOOBB() end)
            if not ok or not bb then return nil, "getSpawnWorldOOBB failed" end
            return bb, nil
        end

        local bb1, e1 = getOOBB(localVehID)
        local bb2, e2 = getOOBB(remoteVehID)
        local haveFn = (type(overlapsOBB_OBB) == 'function')

        local dbgNow = os.clock()
        if TAG_OBB_DEBUG and (dbgNow - lastObbDebugAt) > 0.5 then
            lastObbDebugAt = dbgNow
            print(string.format("PropHunt[TAG-OBB] local=%s remote=%s bb1=%s bb2=%s overlapsFn=%s e1=%s e2=%s",
                tostring(localVehID), tostring(remoteVehID), tostring(bb1 ~= nil), tostring(bb2 ~= nil), tostring(haveFn), tostring(e1), tostring(e2)))
        end

        if bb1 and bb2 and haveFn then
            local ok, hit = pcall(function()
                local he1 = bb1:getHalfExtents()
                local he2 = bb2:getHalfExtents()

                -- Make tagging small props less "pixel perfect" by slightly inflating the target OBB.
                -- This compensates for contact callback noise / very small prop colliders.
                local inflate = 1.45
                local minHalf = 0.55 -- meters-ish; keeps tiny props hittable

                local hx2 = math.max(he2.x * inflate, minHalf)
                local hy2 = math.max(he2.y * inflate, minHalf)
                local hz2 = math.max(he2.z * inflate, minHalf)

                return overlapsOBB_OBB(
                    bb1:getCenter(), bb1:getAxis(0) * he1.x, bb1:getAxis(1) * he1.y, bb1:getAxis(2) * he1.z,
                    bb2:getCenter(), bb2:getAxis(0) * hx2,  bb2:getAxis(1) * hy2,  bb2:getAxis(2) * hz2
                )
            end)

            if TAG_OBB_DEBUG and (dbgNow - lastObbDebugAt) > 0.0 then
                -- (rate-limited by block above)
            end

            -- Hard gate: if OBB says no overlap, do not tag.
            if ok and not hit then
                if TAG_OBB_DEBUG and (dbgNow - lastObbDebugAt) > 0.49 then
                    print("PropHunt[TAG-OBB] result=false (blocked tag)")
                end
                return
            end

            if not ok then
                print("PropHunt[TAG-OBB] ERROR running overlapsOBB_OBB; falling back: " .. tostring(hit))
            end
        else
            -- If we can't run OBB overlap in this environment, we fall back (so the mode stays playable).
        end
    end

    -- Map remote vehicle -> remote playerId using server vehicle string "pid-vid"
    if MPVehicleGE and MPVehicleGE.getServerVehicleID then
        local serverVehID = MPVehicleGE.getServerVehicleID(remoteVehID)
        if serverVehID then
            local remotePid = tonumber(string.match(tostring(serverVehID), "(%d+)%-%d+"))
            if remotePid and TriggerServerEvent then
                -- Outbreak-style contact event
                TriggerServerEvent("PropHunt_onContactReceive", tostring(remotePid))
                return
            end
        end
    end
end

M.sendTagContact = sendTagContact

-- Debug helper: play end-of-round sound right now
M.debugPlayEndSound = function()
    local v = be:getPlayerVehicle(0)
    if not v then
        print("PropHunt debugPlayEndSound: no player vehicle")
        return
    end
    local vehID = v:getID()
    playSound("art/Sounds/Taunts/end.ogg", vehID, 999999, 2.5)
end

return M