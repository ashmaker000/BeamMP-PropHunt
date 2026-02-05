-- lua/ge/extensions/PropHunt.lua
local M = {}

-- --- CONFIG ---
local TAUNT_INTERVAL = 30
local AUTO_TAUNT_ENABLED = false -- disable auto taunt (horn) by default
local TAUNT_SOUND_DISTANCE = 50 -- how far taunts can be heard (reduced from 150)

local SOUND_VOLUME = 1
local MAX_SOUND_LENGTH = 10

local TAUNT_SOUNDS_DIR = "art/Sounds/Taunts/all"
local availableTauntFiles = {}

local function initTauntFiles()
    if not (FS and FS.findFiles) then return end
    local files = FS:findFiles(TAUNT_SOUNDS_DIR, "*.ogg", -1, false, false)
    for _, path in ipairs(files or {}) do
        if string.sub(path, 1, #TAUNT_SOUNDS_DIR) == TAUNT_SOUNDS_DIR then
            availableTauntFiles[#availableTauntFiles + 1] = path
        end
    end
end

local function getRandomTauntSound()
    if #availableTauntFiles == 0 then
        return string.format("%s/taunt%02d.ogg", TAUNT_SOUNDS_DIR, math.random(1, 24))
    end
    return availableTauntFiles[math.random(#availableTauntFiles)]
end

-- --- STATE ---
local runnerID = nil
local propID = nil
local isHidden = false
local tauntTimer = 0
local uiTimer = 0
local activeEmitters = {}

-- UI flash overlay timer (seekers only)
local flashUiTimer = 0

local function validCategory(cat)
    if not cat then return 'info' end
    local normalized = tostring(cat):lower()
    local ok = { info=true, warning=true, error=true, flag=true, success=true }
    return ok[normalized] and normalized or 'info'
end

local function beamMessage(opts)
    if not opts then return end
    local msg = opts.msg or opts.txt or opts.text
    if not msg then return end
    opts.category = validCategory(opts.category or opts.icon)
    opts.msg = msg
    if guihooks and guihooks.trigger then
        guihooks.trigger('Message', opts)
    elseif guihooks and guihooks.message then
        guihooks.message({txt = msg}, opts.ttl or 2, opts.category)
    end
end

-- --- GAME STATE ---
local playerTeam = nil -- "seeker" or "hider"
local gameActive = false
local gameTimer = 0
local lastGameTimer = 0 -- track previous timer value for notifications
local soundEmitterReady = false
local hidePhase = false -- True during 20-second hide countdown
local hideTimer = 0
local assignedPropName = nil
local lastHandledGameStartRound = nil
local lastHandledHidePhaseStartRound = nil
local lastHandledHidePhaseEndRound = nil
local propStateRequestedRound = nil

-- Server-provided hider list (for seeker scan strength). playerId -> true
local hiderIdSet = {}
local seekerIdSet = {} -- for hider-side proximity vignette

local function pidIsSeeker(pid)
    if not pid then return false end
    if seekerIdSet and seekerIdSet[pid] then return true end
    if not seekerIdSet or not next(seekerIdSet) then
        if hiderIdSet and hiderIdSet[pid] then
            return false
        end
        return true
    end
    return false
end

local function pidIsHider(pid)
    if not pid then return false end
    if hiderIdSet and hiderIdSet[pid] then return true end
    if not hiderIdSet or not next(hiderIdSet) then
        if seekerIdSet and seekerIdSet[pid] then
            return false
        end
        return true
    end
    return false
end

-- Seeker proximity vignette settings (server-sent)
local seekerFadeDist = 120
local seekerFilterIntensity = 0.35

-- Hider proximity vignette settings (client-only toggles)
local hiderFadeDist = 120
local hiderFilterIntensity = 0.35

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
local onTeamUpdate
local onSettings

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

local PH_BUILD = "2026-01-30-prophunt-v4"

local function onExtensionLoaded()
    print("DEBUG: PropHunt Core LOADED (" .. PH_BUILD .. ")")

    initTauntFiles()
    print("DEBUG: PropHunt found " .. tostring(#availableTauntFiles) .. " taunt sounds")

    -- Load taunt sound emitter helper (random taunt sounds)
    if extensions and extensions.load then
        local ok, err = pcall(function() extensions.load("soundEmitterControl") end)
        if ok and extensions.soundEmitterControl then
            soundEmitterReady = true
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

    -- Register network event handlers
    -- NOTE: In some BeamMP builds, MPGameNetwork may not be present in GE Lua.
    -- The actual event system is exposed via AddEventHandler/TriggerServerEvent.
    if AddEventHandler then
        AddEventHandler("PropHunt_Taunt", onNetworkTaunt)
        print("DEBUG: Registered handler for PropHunt_Taunt")

        -- Register game state handlers
        AddEventHandler("PropHunt_GameStart", onGameStart)
        print("DEBUG: Registered handler for PropHunt_GameStart")
        AddEventHandler("PropHunt_GameEnd", onGameEnd)
        print("DEBUG: Registered handler for PropHunt_GameEnd")
        AddEventHandler("PropHunt_TimerUpdate", onTimerUpdate)
        print("DEBUG: Registered handler for PropHunt_TimerUpdate")
        AddEventHandler("PropHunt_HidePhaseStart", onHidePhaseStart)
        print("DEBUG: Registered handler for PropHunt_HidePhaseStart")
        AddEventHandler("PropHunt_HideTimerUpdate", onHideTimerUpdate)
        print("DEBUG: Registered handler for PropHunt_HideTimerUpdate")
        AddEventHandler("PropHunt_HidePhaseEnd", onHidePhaseEnd)
        print("DEBUG: Registered handler for PropHunt_HidePhaseEnd")
        AddEventHandler("PropHunt_RoundStart", onRoundStart)
        print("DEBUG: Registered handler for PropHunt_RoundStart")
        AddEventHandler("PropHunt_RoundEnd", onRoundEnd)
        print("DEBUG: Registered handler for PropHunt_RoundEnd")

        AddEventHandler("PropHunt_PlayerEliminated", onPlayerEliminated)
        print("DEBUG: Registered handler for PropHunt_PlayerEliminated")

        AddEventHandler("PropHunt_AssignProp", onAssignProp)
        print("DEBUG: Registered handler for PropHunt_AssignProp")

        -- Register chat command handler
        AddEventHandler("ChatMessageReceived", onChatMessage)
        print("DEBUG: Registered PropHunt chat command handler")

        AddEventHandler("PropHunt_HiderList", onHiderList)
        print("DEBUG: Registered handler for PropHunt_HiderList")
        AddEventHandler("PropHunt_SeekerList", onSeekerList)
        print("DEBUG: Registered handler for PropHunt_SeekerList")
        AddEventHandler("PropHunt_ScanPulse", onScanPulse)
        print("DEBUG: Registered handler for PropHunt_ScanPulse")
        AddEventHandler("PropHunt_TeamUpdate", onTeamUpdate)
        print("DEBUG: Registered handler for PropHunt_TeamUpdate")
        AddEventHandler("PropHunt_Settings", onSettings)
        print("DEBUG: Registered handler for PropHunt_Settings")

        -- Tell server we're ready and request current state (fixes late-load / missed events)
        if TriggerServerEvent then
            TriggerServerEvent("PropHunt_clientReady", "")
            TriggerServerEvent("PropHunt_requestState", "")
        end
    else
        print("ERROR: AddEventHandler not available - BeamMP client events cannot be registered")
    end
end

-- --- AUDIO SYSTEM ---
local function trySoundEmitterExtension(filename, vehID)
    if not soundEmitterReady then return false end
    if not (extensions and extensions.soundEmitterControl and extensions.soundEmitterControl.createSoundEmitter) then
        return false
    end
    if filename and FS and FS.fileExists and not FS:fileExists(filename) then
        return false
    end
    extensions.soundEmitterControl.createSoundEmitter(filename, "PropHunt_SFX_" .. tostring(vehID), vehID)
    return true
end

local function playSound(filename, vehID, maxDistance, volumeOverride)
    if not filename or not vehID then return end
    if not maxDistance and not volumeOverride and trySoundEmitterExtension(filename, vehID) then
        return
    end

    if filename and FS and FS.fileExists and not FS:fileExists(filename) then
        print("PropHunt WARN: sound file missing: " .. tostring(filename))
    end

    -- Remove old emitter if exists
    if activeEmitters[vehID] then
        local oldEmitter = scenetree.findObjectById(activeEmitters[vehID].id)
        if oldEmitter then oldEmitter:delete() end
        activeEmitters[vehID] = nil
    end

    local veh = be:getObjectByID(vehID)
    local pos

    if not veh then
        -- If source vehicle doesn't exist (MP sync issue), play at player position
        print("DEBUG: Source vehicle " .. vehID .. " not found, playing sound at player position")
        local playerVeh = be:getPlayerVehicle(0)
        if not playerVeh then return end
        pos = playerVeh:getPosition()
    else
        pos = veh:getPosition()
    end

    -- Use provided distance or default to taunt distance
    local soundDistance = maxDistance or TAUNT_SOUND_DISTANCE

    local newObj = createObject('SFXEmitter')
    newObj:setPosition(pos)
    newObj:setField('filename', 0, filename)
    newObj:setField('playOnAdd', 0, "1")
    newObj:setField('isLooping', 0, "0")
    newObj:setField('maxDistance', 0, tostring(soundDistance))
    local vol = volumeOverride or SOUND_VOLUME
    newObj:setField('volume', 0, tostring(vol))
    newObj.canSave = false
    newObj:registerObject("PropHunt_SFX_"..vehID)

    local grp = scenetree.MissionGroup
    if grp then grp:addObject(newObj) end
    activeEmitters[vehID] = { id = newObj:getID(), timer = MAX_SOUND_LENGTH }
end

-- --- SEEKER VISUAL BLOCK (hide phase) ---
local function setSeekerVisualBlock(state)
    if extensions and extensions.vignetteShaderAPI then
        if state then
            extensions.vignetteShaderAPI.setEnabled(true)
            extensions.vignetteShaderAPI.setInnerRadius(0.0)
            extensions.vignetteShaderAPI.setOuterRadius(1.0)
            extensions.vignetteShaderAPI.setColor(Point4F(0, 0, 0, 1.0))
        else
            extensions.vignetteShaderAPI.resetVignette()
        end
    end

    if extensions and extensions.prophuntBlurAPI then
        if state then
            extensions.prophuntBlurAPI.setStrength(2.0)
            extensions.prophuntBlurAPI.setEnabled(true)
        else
            extensions.prophuntBlurAPI.reset()
        end
    end
end

local function setProximityVignette(strength, intensity)
    if not extensions or not extensions.vignetteShaderAPI then return end
    local alpha = 0
    if strength and strength > 0 and intensity and intensity > 0 then
        local normalizedStrength = math.min(math.max(strength, 0), 1)
        alpha = math.min(normalizedStrength * math.max(intensity, 0) * 1.4, 0.85)
    end

    if alpha > 0 then
        extensions.vignetteShaderAPI.setEnabled(true)
        extensions.vignetteShaderAPI.setInnerRadius(0.6)
        extensions.vignetteShaderAPI.setOuterRadius(1.2)
        extensions.vignetteShaderAPI.setColor(Point4F(1, 0, 0, alpha))
    else
        extensions.vignetteShaderAPI.resetVignette()
    end
end

local function strengthFromDistance(d, maxDist)
    if not d then return 0 end
    local range = math.max((maxDist or seekerFadeDist or 120), 1)
    local s = 1.0 - math.min(1.0, d / range)
    if s < 0 then s = 0 end
    if s > 1 then s = 1 end
    return s
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

    -- (removed unused Option A spawn+swap state)

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
    for vid, data in pairs(activeEmitters) do
        local emitter = scenetree.findObjectById(data.id)
        if emitter then
            data.timer = data.timer - dt
            if data.timer <= 0 then
                emitter:delete()
                activeEmitters[vid] = nil
            else
                local veh = be:getObjectByID(vid)
                if veh then emitter:setPosition(veh:getPosition()) end
            end
        else
            activeEmitters[vid] = nil
        end
    end

    -- E) (legacy) attached prop syncing no longer used; disguise is via replaceVehicle(prop)

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
    local selectedSound = getRandomTauntSound()
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
    -- data: "roundId,team" (new) or just "team" (legacy)
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

    -- Tell vehicle-side auto extension to start collision checks
    be:queueAllObjectLua("if extensions and extensions.auto_prophunt and extensions.auto_prophunt.setGameRunning then extensions.auto_prophunt.setGameRunning(true) end")

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

    -- Stop collision checks
    be:queueAllObjectLua("if extensions and extensions.auto_prophunt and extensions.auto_prophunt.setGameRunning then extensions.auto_prophunt.setGameRunning(false) end")

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
-- (legacy) attachedPropObjId removed; disguise is vehicle-based

-- store what we were driving before disguising (Option B fallback: replaceVehicle)
local preDisguiseModelKey = nil
local preDisguiseConfig = nil -- best-effort

-- Saved vehicle ids (best-effort). With replaceVehicle disguises these may not stay valid,
-- but we keep them for potential future improvements.
local originalVehId = nil
local propVehId = nil

-- (legacy) object-attached prop + hide helpers removed; disguise is handled via replaceVehicle.

local function spawnAndAttachProp(propName)
    -- Hard idempotency: never transform more than once per round
    if currentRoundId and disguisedRoundId == currentRoundId then
        return
    end
    if disguisedThisRound then return end
    if disguiseInProgress then return end

    disguiseInProgress = true

    -- NOTE: reverted: using replaceVehicle disguise (more reliable in BeamMP).

    if not core_vehicles or not core_vehicles.replaceVehicle or not core_vehicles.getModelList then
        beamMessage({ msg = "Prop disguise failed: core_vehicles API not available", ttl = 4, icon = 'error' })
        print("ERROR: core_vehicles API not available")
        disguiseInProgress = false
        return
    end

    -- Exclusions (known problematic huge props)
    local excluded = {
        flipramp = true,
        kickplate = true,
        large_angletester = true,
        large_bridge = true,
        large_cannon = true,
        large_crusher = true,
        large_hamster_wheel = true,
        large_roller = true,
        large_spinner = true,
        metal_ramp = true,
        weightpad = true,
        suspensionbridge = true,
        rollover = true,
    }

    local function isExcluded(key)
        return excluded[tostring(key)] == true
    end

    local function pickRandomPropModelKey()
        local ok, ml = pcall(function() return core_vehicles.getModelList(true) end)
        if not ok or not ml or not ml.models then return nil end
        local models = ml.models
        if #models == 0 then return nil end

        local attempts = 0
        local chosen
        repeat
            attempts = attempts + 1
            chosen = models[math.random(1, #models)]
        until (chosen and chosen.Type == 'Prop' and not isExcluded(chosen.key)) or attempts > 500

        if chosen and chosen.Type == 'Prop' and not isExcluded(chosen.key) then
            return chosen.key, chosen.Name
        end
        return nil
    end

    local function pickRandomPropConfig(modelKey)
        if not core_vehicles or not core_vehicles.getConfigList then return nil end
        local ok, list = pcall(function() return core_vehicles.getConfigList(true) end)
        if not ok or not list or not list.configs then return nil end

        local configs = {}
        for _, v in pairs(list.configs) do
            if v.model_key == modelKey then
                table.insert(configs, v)
            end
        end
        if #configs == 0 then return nil end

        local c = configs[math.random(#configs)]
        return c and c.key or nil
    end

    local function snapshotVehicleIds()
        local set = {}
        local list = scenetree.findClassObjects('BeamNGVehicle') or {}
        for _, name in ipairs(list) do
            local v = scenetree.findObject(name)
            if v and v.getID then
                set[v:getID()] = true
            end
        end
        return set
    end

    local function findNewVehicleId(before)
        local list = scenetree.findClassObjects('BeamNGVehicle') or {}
        for _, name in ipairs(list) do
            local v = scenetree.findObject(name)
            if v and v.getID then
                local id = v:getID()
                if not before[id] then
                    return id
                end
            end
        end
        return nil
    end

    local modelKey = propName
    local modelLabel = propName

    if tostring(propName) == "random" or tostring(propName) == "" or tostring(propName) == "nil" then
        local k, name = pickRandomPropModelKey()
        if not k then
            beamMessage({ msg = "Prop disguise failed: no prop models found", ttl = 4, icon = 'error' })
            disguiseInProgress = false
            return
        end
        modelKey = k
        modelLabel = name or k
    end

    local function doReplace(key)
        local cfgKey = pickRandomPropConfig(key)
        if cfgKey then
            core_vehicles.replaceVehicle(key, { config = cfgKey })
        else
            core_vehicles.replaceVehicle(key, {})
        end
    end

    local ok, err = pcall(function() doReplace(modelKey) end)

    if not ok then
        print("WARN: replaceVehicle failed for '" .. tostring(modelKey) .. "' => " .. tostring(err) .. "; falling back to random prop")
        local k, name = pickRandomPropModelKey()
        if not k then
            beamMessage({ msg = "Prop disguise failed: " .. tostring(modelKey), ttl = 4, icon = 'error' })
            disguiseInProgress = false
            return
        end
        modelKey = k
        modelLabel = name or k
        ok, err = pcall(function() doReplace(modelKey) end)
    end

    if ok then
        disguisedThisRound = true
        disguisedRoundId = currentRoundId
        propStateRequestedRound = nil
        beamMessage({ msg = "Disguised as prop: " .. tostring(modelLabel), ttl = 4, icon = 'local_shipping' })
        print("DEBUG: Replaced vehicle with prop: " .. tostring(modelKey))
    else
        beamMessage({ msg = "Prop disguise failed: " .. tostring(modelKey), ttl = 4, icon = 'error' })
        print("ERROR: Failed to replace vehicle with prop '" .. tostring(modelKey) .. "': " .. tostring(err))
    end
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
                -- Option A: if we kept the original vehicle, just switch back into it.
                if originalVehId and be:getObjectByID(originalVehId) then
                    local origVeh = be:getObjectByID(originalVehId)
                    pcall(function() origVeh:setActive(1) end)
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
        pcall(function() ov:setActive(1) end)
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
    assignedPropName = nil
end

-- --- CHAT COMMANDS ---
onChatMessage = function(msg)
    -- Parse message format: "sender:message"
    local colonIndex = string.find(msg, ":")
    if not colonIndex then return end

    local message = string.sub(msg, colonIndex + 1, -1)

    -- Check if message is a PropHunt command
    if not message:match("^/ph") then return end

    local args = {}
    for word in message:gmatch("%S+") do
        table.insert(args, word)
    end

    local cmd = args[1]
    local argsSummary = table.concat(args, " " )
    logCommandUsage(cmd, argsSummary)

    if cmd == "/ph" and #args >= 3 and getClientSettingKey(args[2]) then
        table.remove(args, 1)
        table.insert(args, 1, "/phconfig")
        cmd = "/phconfig"
    end

    if cmd == "/phconfig" then
        if #args < 3 then
            beamMessage({
                msg = "Usage: /phconfig <setting> <value>\nSettings: taunt_dist, proximity, proximity_dist, hiderfadedist, hiderfilterintensity",
                ttl = 5,
                icon = 'info'
            })
            return
        end

        local settingKey = getClientSettingKey(args[2])
        local value = tonumber(args[3])

        if not value or not settingKey then
            local hint = "taunt_dist, proximity, proximity_dist, hiderfadedist, hiderfilterintensity"
            beamMessage({
                msg = "Unknown setting or invalid value. Available: " .. hint,
                ttl = 5,
                icon = 'error'
            })
            return
        end

        if settingKey == "taunt_dist" then
            TAUNT_SOUND_DISTANCE = math.max(0, value)
            beamMessage({
                msg = "Taunt sound distance set to " .. TAUNT_SOUND_DISTANCE .. " meters",
                ttl = 3,
                icon = 'check'
            })
        elseif settingKey == "proximity" then
            seekerFilterIntensity = math.max(0, math.min(1, value))
            beamMessage({
                msg = string.format("Seeker proximity intensity set to %.2f", seekerFilterIntensity),
                ttl = 3,
                icon = 'check'
            })
        elseif settingKey == "proximity_dist" then
            seekerFadeDist = math.max(5, value)
            beamMessage({
                msg = "Seeker proximity range set to " .. seekerFadeDist .. " meters",
                ttl = 3,
                icon = 'check'
            })
        elseif settingKey == "hider_fade" then
            hiderFadeDist = math.max(5, value)
            beamMessage({
                msg = "Hider proximity range set to " .. hiderFadeDist .. " meters",
                ttl = 3,
                icon = 'check'
            })
        elseif settingKey == "hider_intensity" then
            hiderFilterIntensity = math.max(0, math.min(1, value))
            beamMessage({
                msg = string.format("Hider proximity intensity set to %.2f", hiderFilterIntensity),
                ttl = 3,
                icon = 'check'
            })
        end
    elseif cmd == "/phtag" then
        -- /phtag <playerId>
        if #args < 2 then
            beamMessage({
                msg = "Usage: /phtag <playerId> (seekers only)",
                ttl = 5,
                icon = 'info'
            })
            return
        end

        local targetId = tonumber(args[2])
        if not targetId then
            beamMessage({
                msg = "Error: playerId must be a number",
                ttl = 3,
                icon = 'error'
            })
            return
        end

        if TriggerServerEvent then
            TriggerServerEvent("PropHunt_TagRequest", tostring(targetId))
            beamMessage({
                msg = "Tag request sent for player " .. tostring(targetId),
                ttl = 2,
                icon = 'near_me'
            })
        else
            beamMessage({
                msg = "Error: TriggerServerEvent not available",
                ttl = 3,
                icon = 'error'
            })
        end

  elseif cmd == "/phhelp" then
        beamMessage({
            msg = "PropHunt Commands:\n" ..
                  "/phconfig <setting> <value> - Configure client distances\n" ..
                  "Settings: taunt_dist, proximity, proximity_dist, hiderfadedist, hiderfilterintensity\n" ..
                  "/phtag <playerId> - (seekers) tag a hider (temporary until automatic tagging)",
            ttl = 9,
            icon = 'help'
        })
    end
end

-- =============================
-- TEAM LISTS (for proximity + scans)
-- =============================
onSeekerList = function(data)
    -- data: "roundId,pid1,pid2,..." or "roundId"
    seekerIdSet = {}

    local parts = {}
    for part in string.gmatch(tostring(data or ""), "[^,]+") do
        table.insert(parts, part)
    end

    if #parts >= 1 then
        local rid = tonumber(parts[1])
        if rid then currentRoundId = rid end
    end

    for i = 2, #parts do
        local pid = tonumber(parts[i])
        if pid then seekerIdSet[pid] = true end
    end
end

-- =============================
-- SEEKER SCAN (client-side strength)
-- =============================
getNearestHiderDistance = function()
    local myVeh = be:getPlayerVehicle(0)
    if not myVeh then return nil end

    local myPos = myVeh:getPosition()
    if not myPos then return nil end

    local best = nil

    -- IMPORTANT: Only iterate MP vehicles to avoid clone/untracked vehicles causing MPVehicleGE errors.
    if not MPVehicleGE or not MPVehicleGE.getVehicles then return nil end

    for _, sv in pairs(MPVehicleGE.getVehicles()) do
        local vid = sv.gameVehicleID
        if vid and myVeh:getID() ~= vid then
            -- Prefer parsing serverVehicleString "pid-idx" if available
            local pid = nil
            if sv.serverVehicleString then
                pid = tonumber(string.match(tostring(sv.serverVehicleString), "(%d+)%-%d+"))
            end
            if not pid then
                pid = resolveOwnerPlayerIdFromVehId(vid)
            end

            if pid and pidIsHider(pid) then
                local v = be:getObjectByID(vid)
                if v and v.getPosition then
                    local p = v:getPosition()
                    if p then
                        local dx = (p.x - myPos.x)
                        local dy = (p.y - myPos.y)
                        local dz = (p.z - myPos.z)
                        local d = math.sqrt(dx*dx + dy*dy + dz*dz)
                        if not best or d < best then best = d end
                    end
                end
            end
        end
    end

    return best
end

getNearestSeekerDistance = function()
    local myVeh = be:getPlayerVehicle(0)
    if not myVeh then
        closestHunterInfo = {}
        return nil
    end

    local myPos = myVeh:getPosition()
    if not myPos then
        closestHunterInfo = {}
        return nil
    end

    local best = nil
    local bestPid = nil
    local bestVid = nil

    -- IMPORTANT: Only iterate MP vehicles to avoid clone/untracked vehicles causing MPVehicleGE errors.
    if not MPVehicleGE or not MPVehicleGE.getVehicles then
        closestHunterInfo = {}
        return nil
    end

    for _, sv in pairs(MPVehicleGE.getVehicles()) do
        local vid = sv.gameVehicleID
        if vid and myVeh:getID() ~= vid then
            local pid = nil
            if sv.serverVehicleString then
                pid = tonumber(string.match(tostring(sv.serverVehicleString), "(%d+)%-%d+"))
            end
            if not pid then
                pid = resolveOwnerPlayerIdFromVehId(vid)
            end

            if pid and pidIsSeeker(pid) then
                local v = be:getObjectByID(vid)
                if v and v.getPosition then
                    local p = v:getPosition()
                    if p then
                        local dx = (p.x - myPos.x)
                        local dy = (p.y - myPos.y)
                        local dz = (p.z - myPos.z)
                        local d = math.sqrt(dx*dx + dy*dy + dz*dz)
                        if not best or d < best then
                            best = d
                            bestPid = pid
                            bestVid = vid
                        end
                    end
                end
            end
        end
    end

    if best then
        closestHunterInfo = {
            pid = bestPid,
            vid = bestVid,
            dist = best,
            name = hunterNameForPid(bestPid)
        }
    else
        closestHunterInfo = {}
    end

    return best
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
    -- data: "roundId,pid1,pid2,..." or "roundId"
    hiderIdSet = {}

    local parts = {}
    for part in string.gmatch(tostring(data or ""), "[^,]+") do
        table.insert(parts, part)
    end

    -- parts[1] = roundId
    if #parts >= 1 then
        local rid = tonumber(parts[1])
        if rid then currentRoundId = rid end
    end

    for i = 2, #parts do
        local pid = tonumber(parts[i])
        if pid then hiderIdSet[pid] = true end
    end

    print("DEBUG: Received hider list (" .. tostring(#parts - 1) .. " hiders)")
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
    -- data: "roundId,seekerFadeDist,seekerFilterIntensity,hiderFadeDist,hiderFilterIntensity"
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
    -- Best method (used in Outbreak): convert gameVehicleID -> serverVehicleID -> playerId
    -- serverVehicleID format: "<playerId>-<vehicleIndex>" (e.g. "1-0")
    if not vehId then return nil end

    if MPVehicleGE and MPVehicleGE.getServerVehicleID then
        local ok, serverVeh = pcall(function() return MPVehicleGE.getServerVehicleID(vehId) end)
        if ok and serverVeh then
            local pid = string.match(tostring(serverVeh), "(%d+)%-%d+")
            if pid then return tonumber(pid) end
        end
    end

    -- fallback attempts (older/alt APIs)
    local candidates = {
        function()
            if MPVehicleGE and MPVehicleGE.getOwnerID then return MPVehicleGE.getOwnerID(vehId) end
        end,
        function()
            if MPVehicleGE and MPVehicleGE.getVehicleOwner then return MPVehicleGE.getVehicleOwner(vehId) end
        end,
        function()
            if MPVehicleGE and MPVehicleGE.getOwner then return MPVehicleGE.getOwner(vehId) end
        end,
        function()
            if MPGameNetwork and MPGameNetwork.getVehicleOwner then return MPGameNetwork.getVehicleOwner(vehId) end
        end,
    }

    for _, fn in ipairs(candidates) do
        local ok, res = pcall(fn)
        if ok and res ~= nil then
            local n = tonumber(res)
            if n then return n end
        end
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

-- (legacy) updateAttachedPropTransform removed

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