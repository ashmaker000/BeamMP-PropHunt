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
local forceGhostOffOnRestore = true
local spawnswapRetryCount = 2
local spawnswapDisabledRound = nil
local spawnswapDisabledReason = nil
local preSpawnAttemptedRound = nil
local cleanupSweepSeconds = 15
local seekerTabPrevention = true
local allowNodeGrabInRound = false
local allowHiderResetInRound = false
local hideNametagsInRound = true
local seekerSyncDelayAfterHide = 1.2
local seekerLockedVehId = nil
local lastSeekerTabWarnAt = 0
local lastLegalPlayerPos = nil
local lastLegalPlayerRot = nil
local antiTeleportMaxMetersPerFrame = 35
local antiTeleportMaxDt = 0.5

local actionFilterGlobalActive = false
local actionFilterHiderActive = false
local topCameraResolvedName = nil
local topCameraResolveAttempted = false
local globalBlockedActions = {
    "freeCamera", "toggleFreeCamera", "cameraFree",
    "dropPlayerAtCamera", "dropPlayerAtCameraNoReset",
    "nodeGrabber", "nodegrabber", "nodegrabberGrab", "nodegrabberRotate", "nodegrabberTranslate"
}
local hiderBlockedActions = {
    "recover", "recover_vehicle", "recover_vehicle_alt",
    "reset_physics", "reset_all_physics",
    "loadHome", "saveHome",
    "boost", "jump", "nitrous", "activateNitrous", "toggleNitrous",
    "funStuffBoost", "funStuffJump", "vehicleDebugBoost", "arcadeBoost"
}
local movingResetBlockedActions = {
    "dropPlayerAtCamera", "dropPlayerAtCameraNoReset",
    "recover", "recover_vehicle", "recover_vehicle_alt", "recover_to_last_road",
    "reset_physics", "reset_all_physics", "reload_vehicle", "reload_all_vehicles"
}
local movingResetLockActive = false
local disableResetsWhenMoving = true
local maxResetMovingSpeed = 2.0
local movementResetGraceSeconds = 5.0
local movementResetTimer = 0
local lastMovementPos = vec3()
local lastMovementPosReady = false
local lastHudPulseMsgAt = 0
local lastHudPulseKey = ""
local postRoundCleanupUntil = 0
local lastNametagEnforceAt = 0
local lastPostRoundCleanupSweepAt = 0
local pendingHardDelete = {} -- serverVehicleString -> dueTime
local hardNametagMaskActive = false

-- Round identity (server-sent) + idempotency
local currentRoundId = nil

-- Disguise gating: only allow prop transform after hide phase ends / round starts
local allowDisguise = false
local disguisedThisRound = false
local disguisedRoundId = nil
local disguiseInProgress = false
local roundEndRestoreAppliedRound = nil
local gameEndRestoreAppliedRound = nil
local localEliminatedRestoreRound = nil
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
local clearTempPropsForOwnerPid
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
local onHudPulse
local onKillcamPulse
local onCooldownHint
local onSpawnHint
local onTempPropClear
local onTempPropClearOwner
local onForceSync
local hardClearAllTempProps
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

local PH_BUILD = "2026-02-25-topcam-lock"

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
    topCameraResolvedName = nil
    topCameraResolveAttempted = false

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
    roundEndRestoreAppliedRound = nil
    gameEndRestoreAppliedRound = nil
    localEliminatedRestoreRound = nil
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
        onHudPulse = onHudPulse,
        onKillcamPulse = onKillcamPulse,
        onCooldownHint = onCooldownHint,
        onSpawnHint = onSpawnHint,
        onTempPropClear = onTempPropClear,
        onTempPropClearOwner = onTempPropClearOwner,
        onForceSync = onForceSync,
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

local function getCombinePassFX()
    if not scenetree then return nil end
    return scenetree["PostEffectCombinePassObject"] or scenetree.findObject("PostEffectCombinePassObject")
end

local function clearSeekerBlackoutFallback()
    local fx = getCombinePassFX()
    if fx and fx.setField then
        pcall(function() fx:setField("enableBlueShift", 0, 0) end)
        pcall(function() fx:setField("blueShiftColor", 0, "0 0 0") end)
    end
end

local function forceSeekerBlackoutNow()
    if not (hidePhase and playerTeam == "seeker") then return end

    if extensions and not extensions.vignetteShaderAPI and extensions.load then
        pcall(function() extensions.load("vignetteShaderAPI") end)
    end
    if extensions and not extensions.prophuntBlurAPI and extensions.load then
        pcall(function() extensions.load("prophuntBlurAPI") end)
    end

    if extensions and extensions.vignetteShaderAPI then
        pcall(function()
            extensions.vignetteShaderAPI.setEnabled(true)
            extensions.vignetteShaderAPI.setInnerRadius(0.0)
            extensions.vignetteShaderAPI.setOuterRadius(0.0)
            extensions.vignetteShaderAPI.setColor(Point4F(0, 0, 0, 1.0))
        end)
    end

    if extensions and extensions.prophuntBlurAPI then
        pcall(function()
            extensions.prophuntBlurAPI.setStrength(3.0)
            extensions.prophuntBlurAPI.setEnabled(true)
        end)
    end

    -- Fallback for builds where vignette pipeline is unreliable:
    -- force full-screen darkening through combine pass.
    local fx = getCombinePassFX()
    if fx and fx.setField then
        pcall(function() fx:setField("enableBlueShift", 0, 1) end)
        pcall(function() fx:setField("blueShiftColor", 0, "0 0 0") end)
    end
end

local function forceLocalVehicleVisible()
    local veh = be:getPlayerVehicle(0)
    if not veh then return end
    pcall(function() veh:queueLuaCommand('obj:setGhostEnabled(false)') end)
    pcall(function()
        if core_vehicleBridge and core_vehicleBridge.executeAction then
            core_vehicleBridge.executeAction(veh, 'setFreeze', false)
        end
    end)
end

local function resolveTopCameraNameOnce()
    if topCameraResolveAttempted then return end
    topCameraResolveAttempted = true

    local candidates = { "topDown", "cameraTopDown", "cameraTop", "topdown" }
    local discovered = {}
    pcall(function()
        if core_camera and core_camera.getPlayerCameras then
            local cams = core_camera.getPlayerCameras(0)
            if type(cams) == "table" then
                for _, c in pairs(cams) do
                    if type(c) == "table" and c.name then table.insert(discovered, tostring(c.name))
                    elseif type(c) == "string" then table.insert(discovered, tostring(c)) end
                end
            end
        end
    end)

    local function trySet(name)
        local okAny = false
        if commands and commands.setGameCamera then
            local ok = pcall(function() commands.setGameCamera(name) end)
            okAny = okAny or ok
        end
        if core_camera and core_camera.setByName then
            local okA = pcall(function() core_camera.setByName(name) end)
            local okB = pcall(function() core_camera.setByName(0, name) end)
            okAny = okAny or okA or okB
        end
        if core_camera and core_camera.setCameraByName then
            local okA = pcall(function() core_camera.setCameraByName(name) end)
            local okB = pcall(function() core_camera.setCameraByName(0, name) end)
            okAny = okAny or okA or okB
        end
        return okAny
    end

    for _, n in ipairs(discovered) do
        local low = string.lower(n)
        if string.find(low, "top", 1, true) and trySet(n) then
            topCameraResolvedName = n
            break
        end
    end

    if not topCameraResolvedName then
        for _, n in ipairs(candidates) do
            if trySet(n) then
                topCameraResolvedName = n
                break
            end
        end
    end

    print("[PH] top-camera resolved=" .. tostring(topCameraResolvedName or "topDown"))
end

local function enforceSeekerHideTopCamera()
    if not (gameActive and hidePhase and playerTeam == "seeker") then return end
    resolveTopCameraNameOnce()
    local name = topCameraResolvedName or "topDown"
    pcall(function()
        if commands and commands.setGameCamera then commands.setGameCamera(name) end
        if core_camera and core_camera.setByName then
            core_camera.setByName(name)
            core_camera.setByName(0, name)
        end
        if core_camera and core_camera.setCameraByName then
            core_camera.setCameraByName(name)
            core_camera.setCameraByName(0, name)
        end
    end)
end

local function enforceHiderAbilityLock()
    if not (gameActive and playerTeam == "hider") then return end
    local veh = be:getPlayerVehicle(0)
    if not veh then return end
    local cmd = [[
      if input and input.event then
        local kill = {
          'boost','jump','dropPlayerAtCameraNoReset'
        }
        for _, a in ipairs(kill) do input.event(a, 0, 2) end
      end
    ]]
    pcall(function() veh:queueLuaCommand(cmd) end)
    if not allowNodeGrabInRound then
        pcall(function()
            if input and input.event then
                input.event('nodeGrabber', 0, 2)
                input.event('nodegrabber', 0, 2)
                input.event('nodegrabberGrab', 0, 2)
                input.event('nodegrabberRotate', 0, 2)
                input.event('nodegrabberTranslate', 0, 2)
            end
        end)
    end
    if not allowHiderResetInRound then
        pcall(function()
            if input and input.event then
                input.event('recover', 0, 2)
                input.event('recover_vehicle', 0, 2)
                input.event('reset_physics', 0, 2)
                input.event('reset_all_physics', 0, 2)
            end
        end)
    end
end

local function getGlobalBlockedActions()
    local list = {}
    for _, a in ipairs(globalBlockedActions) do
        local aa = tostring(a)
        local isNode = (aa == "nodeGrabber" or aa == "nodegrabber" or aa == "nodegrabberGrab" or aa == "nodegrabberRotate" or aa == "nodegrabberTranslate")
        if not (allowNodeGrabInRound and isNode) then
            list[#list + 1] = aa
        end
    end
    return list
end

local function getHiderBlockedActions()
    local list = {}
    for _, a in ipairs(hiderBlockedActions) do
        local aa = tostring(a)
        local isReset = (aa == "recover" or aa == "recover_vehicle" or aa == "recover_vehicle_alt" or aa == "reset_physics" or aa == "reset_all_physics")
        if not (allowHiderResetInRound and isReset) then
            list[#list + 1] = aa
        end
    end
    return list
end

local function enforceActionFilters()
    if not core_input_actionFilter then return end

    local shouldGlobal = (gameActive == true)
    if shouldGlobal ~= actionFilterGlobalActive then
        core_input_actionFilter.setGroup("ph_global_lock", getGlobalBlockedActions())
        core_input_actionFilter.addAction(0, "ph_global_lock", shouldGlobal)
        actionFilterGlobalActive = shouldGlobal
    end

    local shouldHider = (gameActive == true and playerTeam == "hider")
    if shouldHider ~= actionFilterHiderActive then
        core_input_actionFilter.setGroup("ph_hider_lock", getHiderBlockedActions())
        core_input_actionFilter.addAction(0, "ph_hider_lock", shouldHider)
        actionFilterHiderActive = shouldHider
    end
end

local function enforceGlobalCheatKeyLock()
    if not gameActive then return end
    pcall(function()
      if input and input.event then
        input.event('freeCamera', 0, 2)
        input.event('toggleFreeCamera', 0, 2)
        input.event('dropPlayerAtCamera', 0, 2)
        input.event('dropPlayerAtCameraNoReset', 0, 2)
        if not allowNodeGrabInRound then input.event('nodeGrabber', 0, 2) end
      end
    end)
end

local function enforceMovingResetLock(dt)
    if not core_input_actionFilter then return end
    local shouldBlock = false

    if gameActive and disableResetsWhenMoving then
        local veh = be:getPlayerVehicle(0)
        if veh and veh.getID and veh.getVelocityXYZ then
            local vid = veh:getID()
            local own = true
            if MPVehicleGE and MPVehicleGE.isOwn then
                local okOwn, isOwnVeh = pcall(function() return MPVehicleGE.isOwn(vid) end)
                if okOwn then own = (isOwnVeh == true) end
            end

            if own then
                local pos = vec3(be:getObjectOOBBCenterXYZ(vid))
                local vel = vec3(veh:getVelocityXYZ())

                if lastMovementPosReady then
                    if pos:squaredDistance(lastMovementPos) > (1.0 * 1.0) then
                        movementResetTimer = movementResetGraceSeconds
                        lastMovementPos:set(pos)
                    else
                        movementResetTimer = math.max(0, movementResetTimer - (dt or 0))
                    end
                else
                    lastMovementPos:set(pos)
                    lastMovementPosReady = true
                end

                shouldBlock = (vel:length() >= (maxResetMovingSpeed or 2.0)) or (movementResetTimer > 0)
            end
        end
    end

    if shouldBlock ~= movingResetLockActive then
        core_input_actionFilter.setGroup("ph_moving_reset_lock", movingResetBlockedActions)
        core_input_actionFilter.addAction(0, "ph_moving_reset_lock", shouldBlock)
        movingResetLockActive = shouldBlock
    end

    if not gameActive then
        movementResetTimer = 0
        lastMovementPosReady = false
    end
end

local function enforceAntiTeleport(dt)
    if not gameActive then
        lastLegalPlayerPos = nil
        lastLegalPlayerRot = nil
        return
    end

    local veh = be:getPlayerVehicle(0)
    if not veh then return end
    local pos = veh:getPosition()
    local rot = veh:getRotation()
    if not pos then return end

    if lastLegalPlayerPos then
        local dx = (pos.x or 0) - (lastLegalPlayerPos.x or 0)
        local dy = (pos.y or 0) - (lastLegalPlayerPos.y or 0)
        local dz = (pos.z or 0) - (lastLegalPlayerPos.z or 0)
        local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
        if dist >= antiTeleportMaxMetersPerFrame then
            local rx, ry, rz, rw = 0, 0, 0, 1
            if lastLegalPlayerRot then
                rx, ry, rz, rw = lastLegalPlayerRot.x, lastLegalPlayerRot.y, lastLegalPlayerRot.z, lastLegalPlayerRot.w
            end
            pcall(function()
                veh:setPositionRotation(lastLegalPlayerPos.x, lastLegalPlayerPos.y, lastLegalPlayerPos.z, rx, ry, rz, rw)
            end)
            beamMessage({ msg = "Teleport blocked", ttl = 1.2, icon = 'block' })
            return
        end
    end

    lastLegalPlayerPos = vec3(pos.x, pos.y, pos.z)
    if rot then
        lastLegalPlayerRot = quat(rot.x, rot.y, rot.z, rot.w)
    end
end

local function queueHardDelete(serverVeh, delaySec)
    local sv = tostring(serverVeh or "")
    if sv == "" then return end
    pendingHardDelete[sv] = os.clock() + (tonumber(delaySec) or 2.5)
end

local function enforceNametagHardMask(enabled)
    if not MPVehicleGE then return end

    -- Player-level mask (hides all roles/prefix/suffix labels like Dev/CC too)
    if MPVehicleGE.getPlayers then
        for _, p in pairs(MPVehicleGE.getPlayers() or {}) do
            if type(p) == "table" then
                p.hideNametag = (enabled == true)
                if enabled == true then
                    p.name = ""
                    p.playerName = ""
                    p.nickname = ""
                    p.ownerName = ""
                    p.shortname = ""
                    p.nickPrefixes = {}
                    p.nickSuffixes = {}
                    if p.role then
                        p.role.name = ""
                        p.role.tag = ""
                        p.role.shorttag = ""
                    end
                    pcall(function() if p.setDisplayName then p:setDisplayName("") end end)
                    pcall(function() if p.clearCustomRole then p:clearCustomRole() end end)
                end
            end
        end
    end

    -- Vehicle-level mask as backup
    if MPVehicleGE.getVehicles then
        for _, v in pairs(MPVehicleGE.getVehicles() or {}) do
            if type(v) == "table" then
                v.hideNametag = (enabled == true)
                if enabled == true then
                    v.ownerName = ""
                    v.nickname = ""
                    v.shortname = ""
                    v.nickPrefixes = {}
                    v.nickSuffixes = {}
                    if v.role then
                        v.role.name = ""
                        v.role.tag = ""
                        v.role.shorttag = ""
                    end
                    pcall(function() if v.setDisplayName then v:setDisplayName("") end end)
                    pcall(function() if v.clearCustomRole then v:clearCustomRole() end end)
                end
            end
        end
    end

    hardNametagMaskActive = (enabled == true)
end


local function scrubTempVehicleNameMetadata()
    if not MPVehicleGE or not MPVehicleGE.getVehicles then return end
    for _, veh in pairs(MPVehicleGE.getVehicles() or {}) do
        local svs = tostring(veh.serverVehicleString or "")
        local _, idxStr = string.match(svs, "^(%d+)%-(%d+)$")
        local idx = tonumber(idxStr)
        if idx and idx > 0 then
            veh.hideNametag = true
            veh.ownerName = ""
            veh.nickname = ""
            veh.shortname = ""
            veh.nickPrefixes = {}
            veh.nickSuffixes = {}
            if veh.role then
                veh.role.name = ""
                veh.role.tag = ""
                veh.role.shorttag = ""
            end
            pcall(function() if veh.setDisplayName then veh:setDisplayName("") end end)
            pcall(function() if veh.clearCustomRole then veh:clearCustomRole() end end)
        end
    end
end

local function shouldApplyNametagMaskNow()
    -- Only seekers should have nametags hidden during active rounds.
    return (gameActive == true and hideNametagsInRound == true and tostring(playerTeam or "") == "seeker")
end

local function pulseNicknameRenderer()
    if not MPVehicleGE or not MPVehicleGE.hideNicknames then return end
    local desired = shouldApplyNametagMaskNow() and true or false
    pcall(function() MPVehicleGE.hideNicknames(not desired) end)
    if scheduler and scheduler.add then
        local t = 0
        scheduler.add(function(dt)
            t = t + (dt or 0)
            if t >= 0.15 then
                pcall(function() MPVehicleGE.hideNicknames(desired) end)
                enforceNametagHardMask(desired)
                return false
            end
            return true
        end)
    else
        pcall(function() MPVehicleGE.hideNicknames(desired) end)
        enforceNametagHardMask(desired)
    end
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

    -- Network broadcast (prefer serverVehicleString for cross-client correctness)
    if MPCoreNetwork and MPCoreNetwork.isMPSession() and TriggerServerEvent then
        local payload = nil
        if MPVehicleGE and MPVehicleGE.getServerVehicleID then
            local ok, sv = pcall(function() return MPVehicleGE.getServerVehicleID(vehId) end)
            if ok and sv then payload = tostring(sv) end
        end
        TriggerServerEvent("PropHunt_TauntRequest", tostring(payload or vehId))
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

    enforceActionFilters()
    enforceMovingResetLock(dt)
    enforceAntiTeleport(dt)
    if gameActive then
        enforceSeekerHideTopCamera()
        enforceGlobalCheatKeyLock()
    end
    if playerTeam == "hider" and gameActive then
        enforceHiderAbilityLock()
    end

    -- Keep nametag suppression sticky even when MPVehicleGE updates vehicle data mid-round.
    local nowMask = os.clock()
    if (nowMask - (lastNametagEnforceAt or 0)) >= 0.5 then
        lastNametagEnforceAt = nowMask
        local desiredMask = shouldApplyNametagMaskNow()
        enforceNametagHardMask(desiredMask)
        if MPVehicleGE and MPVehicleGE.hideNicknames then
            if desiredMask then
                pcall(function() MPVehicleGE.hideNicknames(true) end)
                scrubTempVehicleNameMetadata()
            else
                pcall(function() MPVehicleGE.hideNicknames(false) end)
            end
        end
    end

    -- Post-round safety sweep: for a short window after round/game end,
    -- repeatedly dedupe owner vehicles to kill late stale nametags.
    if (not gameActive) and postRoundCleanupUntil and os.clock() < postRoundCleanupUntil then
        if (os.clock() - (lastPostRoundCleanupSweepAt or 0)) >= 1.0 then
            hardClearAllTempProps()
            if cleanupTempSpawnSwapProps then cleanupTempSpawnSwapProps() end
            lastPostRoundCleanupSweepAt = os.clock()
        end
    end

    -- Deferred hard-delete disabled:
    -- deleting MPVehicleGE entries client-side races with late network packets
    -- (coupler/state updates), causing nil-vehicle exceptions in MPVehicleGE.
    -- We only clear pending markers now; no direct delete() calls from PropHunt.
    if (not gameActive) then
        local nowT = os.clock()
        for svs, due in pairs(pendingHardDelete) do
            if nowT >= (due or 0) then
                pendingHardDelete[svs] = nil
            end
        end
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

    -- TAB prevention: block switching into non-owned vehicles during active round.
    -- Applied to all roles to prevent remote-vehicle tab races / forced spawns.
    if gameActive and seekerTabPrevention then
        local veh = be:getPlayerVehicle(0)
        if veh then
            local vid = veh:getID()
            local own = true
            if MPVehicleGE and MPVehicleGE.isOwn then
                local okOwn, isOwn = pcall(function() return MPVehicleGE.isOwn(vid) end)
                if okOwn and isOwn ~= nil then own = (isOwn == true) end
            end

            if own then
                seekerLockedVehId = vid
            else
                local target = seekerLockedVehId and be:getObjectByID(seekerLockedVehId) or nil
                if not target and MPVehicleGE and MPVehicleGE.getVehicles and MPVehicleGE.isOwn then
                    for _, v in pairs(MPVehicleGE.getVehicles() or {}) do
                        local gvid = tonumber(v and v.gameVehicleID)
                        if gvid and MPVehicleGE.isOwn(gvid) then
                            target = be:getObjectByID(gvid)
                            if target then
                                seekerLockedVehId = gvid
                                break
                            end
                        end
                    end
                end
                if target then
                    pcall(function() be:enterVehicle(0, target) end)
                    local t = os.clock and os.clock() or 0
                    if (t - lastSeekerTabWarnAt) > 1.5 then
                        lastSeekerTabWarnAt = t
                        beamMessage({ msg = "TAB switch blocked", ttl = 1.2, icon = 'block' })
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

    -- Hard-override: seeker hide phase must remain fully black every frame.
    forceSeekerBlackoutNow()

    -- AUTO TAUNT
    -- Keep nametags hidden for everyone throughout active rounds
    -- (some builds/UI refreshes can re-enable them).
    if shouldApplyNametagMaskNow() and MPVehicleGE and MPVehicleGE.hideNicknames then
        MPVehicleGE.hideNicknames(true)
        enforceNametagHardMask(true)
    elseif hardNametagMaskActive then
        enforceNametagHardMask(false)
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
    local raw = tostring(data or "")
    local vehID = tonumber(raw)

    if not vehID and MPVehicleGE and MPVehicleGE.getVehicles then
      for _, veh in pairs(MPVehicleGE.getVehicles() or {}) do
        if tostring(veh.serverVehicleString or "") == raw then
          vehID = tonumber(veh.gameVehicleID)
          break
        end
      end
    end

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
    spawnswapDisabledRound = nil
    spawnswapDisabledReason = nil
    preSpawnAttemptedRound = nil
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
    roundEndRestoreAppliedRound = nil
    gameEndRestoreAppliedRound = nil
    localEliminatedRestoreRound = nil

    resetRoundState(roundId)

    if not team then
        team = tostring(data or "")
    end

    playerTeam = team
    gameActive = true
    seekerLockedVehId = nil
    pendingHardDelete = {}
    gameTimer = 300
    lastGameTimer = 300 -- reset timer tracking
    lastLegalPlayerPos = nil
    lastLegalPlayerRot = nil

    -- Ensure vehicle-side hooks are loaded, then start collision checks.
    ensureVehicleExtensionsLoaded(true)

    -- Safety sweep for stale temp props from old rounds/builds.
    if cleanupTempSpawnSwapProps then cleanupTempSpawnSwapProps() end

    -- Hide nametags for everyone during active rounds
    -- (apply immediately + delayed to beat BeamMP UI refresh).
    if shouldApplyNametagMaskNow() and MPVehicleGE and MPVehicleGE.hideNicknames then
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

    if team == "seeker" then
        local sv = be:getPlayerVehicle(0)
        seekerLockedVehId = sv and sv:getID() or seekerLockedVehId
        beamMessage({
            msg = "You are a SEEKER! Find and tag the hiders!",
            ttl = 5,
            icon = 'visibility'
        })
        print("DEBUG: You are a SEEKER")

        -- If role assignment arrives after hide phase already started, enforce now.
        if hidePhase then
            beginSeekerHidePhaseEnforcement()
        end
    else
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

    -- Safety: if round-end restore was missed due to event ordering, force one here once per round.
    if currentRoundId and (gameEndRestoreAppliedRound == currentRoundId or roundEndRestoreAppliedRound == currentRoundId or localEliminatedRestoreRound == currentRoundId) then
        -- already restored for this round end sequence
    elseif preDisguiseModelKey and core_vehicles and core_vehicles.replaceVehicle then
        local okRep, errRep = pcall(function()
            if preDisguiseConfig and preDisguiseConfig ~= '' then
                core_vehicles.replaceVehicle(preDisguiseModelKey, { config = preDisguiseConfig })
            else
                core_vehicles.replaceVehicle(preDisguiseModelKey, {})
            end
        end)
        if okRep then
            print("[PH] game-end forced restore -> " .. tostring(preDisguiseModelKey))
        else
            print("WARN: game-end forced restore failed: " .. tostring(errRep))
        end
        if currentRoundId then gameEndRestoreAppliedRound = currentRoundId end
    end

    playerTeam = nil
    gameActive = false
    disguisedThisRound = false
    disguisedRoundId = nil
    gameTimer = 0
    lastGameTimer = 0 -- reset timer tracking
    hidePhase = false
    hideTimer = 0
    allowDisguise = false
    seekerLockedVehId = nil
    lastLegalPlayerPos = nil
    lastLegalPlayerRot = nil

    setSeekerVisualBlock(false)
    clearSeekerBlackoutFallback()

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
    pulseNicknameRenderer()

    -- Stop vehicle-side collision checks.
    ensureVehicleExtensionsLoaded(false)

    forceLocalVehicleVisible()
    if scheduler and scheduler.add then
        local t = 0
        scheduler.add(function(dt)
            t = t + (dt or 0)
            if t >= 0.25 then
                forceLocalVehicleVisible()
                return false
            end
            return true
        end)
    end

    if cleanupTempSpawnSwapProps then cleanupTempSpawnSwapProps() end
    postRoundCleanupUntil = os.clock() + 10.0
    lastPostRoundCleanupSweepAt = 0

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
local preDisguiseModelKey = nil
local preDisguiseConfig = nil

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
        getForceGhostOffOnRestore = function() return forceGhostOffOnRestore end,
        getSpawnswapRetryCount = function() return spawnswapRetryCount end,
        isSpawnswapDisabledForRound = function()
            return currentRoundId and spawnswapDisabledRound == currentRoundId
        end,
        disableSpawnswapForRound = function(reason)
            if currentRoundId then
                spawnswapDisabledRound = currentRoundId
                spawnswapDisabledReason = tostring(reason or "unknown")
                print("[PH] spawnswap disabled for round " .. tostring(currentRoundId) .. " reason=" .. tostring(spawnswapDisabledReason))
                beamMessage({ msg = "Spawnswap disabled: " .. tostring(spawnswapDisabledReason), ttl = 3, icon = 'warning' })
            end
        end,
        getCurrentRoundId = function() return currentRoundId end,
        getPlayerTeam = function() return playerTeam end,
        getOriginalVehId = function() return originalVehId end,
        setOriginalVehId = function(v) originalVehId = v end,
        getPropVehId = function() return propVehId end,
        setPropVehId = function(v) propVehId = v end,
        getPreDisguiseModelKey = function() return preDisguiseModelKey end,
        setPreDisguiseModelKey = function(v) preDisguiseModelKey = v end,
        getPreDisguiseConfig = function() return preDisguiseConfig end,
        setPreDisguiseConfig = function(v) preDisguiseConfig = v end,
    }, propName)
end

preSpawnIfNeeded = function()
    if playerTeam ~= "hider" then return end
    if not assignedPropName or assignedPropName == "" then return end
    if currentRoundId and spawnswapDisabledRound == currentRoundId then return end
    disguiseMod.preSpawnProp({
        getDisguiseMode = function() return disguiseMode end,
        getForceGhostOffOnRestore = function() return forceGhostOffOnRestore end,
        getSpawnswapRetryCount = function() return spawnswapRetryCount end,
        isPreSpawnAttemptedThisRound = function()
            return currentRoundId and preSpawnAttemptedRound == currentRoundId
        end,
        markPreSpawnAttemptedThisRound = function()
            if currentRoundId then preSpawnAttemptedRound = currentRoundId end
        end,
        isSpawnswapDisabledForRound = function()
            return currentRoundId and spawnswapDisabledRound == currentRoundId
        end,
        disableSpawnswapForRound = function(reason)
            if currentRoundId then
                spawnswapDisabledRound = currentRoundId
                spawnswapDisabledReason = tostring(reason or "unknown")
                print("[PH] pre-spawn disabled for round " .. tostring(currentRoundId) .. " reason=" .. tostring(spawnswapDisabledReason))
                beamMessage({ msg = "Pre-spawn disabled: " .. tostring(spawnswapDisabledReason), ttl = 3, icon = 'warning' })
            end
        end,
        getCurrentRoundId = function() return currentRoundId end,
        getPlayerTeam = function() return playerTeam end,
        getPropVehId = function() return propVehId end,
        setPropVehId = function(v) propVehId = v end,
        setOriginalVehId = function(v) originalVehId = v end,
    }, assignedPropName)
end

local function beginSeekerHidePhaseEnforcement()
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
            enforceSeekerHideTopCamera()
            if not hidePhase then
                hideCameraTask = nil
                return false
            end
            return true
        end)
    else
        enforceSeekerHideTopCamera()
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
    preSpawnIfNeeded()

    -- If we missed early AssignProp (late-loaded), request current state again.
    if playerTeam == "hider" and (not assignedPropName or assignedPropName == "") and TriggerServerEvent then
        local t = os.clock()
        if (t - lastStateRequestAt) > 1.0 then
            lastStateRequestAt = t
            TriggerServerEvent("PropHunt_requestState", "")
        end
    end

    -- Freeze seeker + enforce top camera during hide phase
    if playerTeam == "seeker" then
        beginSeekerHidePhaseEnforcement()
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
        local function releaseSeekerForHunt()
            local playerVeh = be:getPlayerVehicle(0)
            if playerVeh then
                core_vehicleBridge.executeAction(playerVeh, 'setFreeze', false)
                print("DEBUG: Seeker vehicle unfrozen - hunt begins!")
            end

            setSeekerVisualBlock(false)
            clearSeekerBlackoutFallback()
            applyHideCameraLock(false)
            if hideVisualTask then hideVisualTask = nil end
            if hideCameraTask then hideCameraTask = nil end

            -- Return camera to orbit when round starts (nice default)
            pcall(function()
                if commands and commands.setGameCamera then
                    commands.setGameCamera('orbit')
                elseif core_camera and core_camera.setByName then
                    core_camera.setByName('orbit')
                end
            end)

            beamMessage({ msg = "Hunt begins NOW!", ttl = 3, icon = 'visibility' })
        end

        local syncDelay = tonumber(seekerSyncDelayAfterHide or 0) or 0
        if syncDelay > 0 and scheduler and scheduler.add then
            beamMessage({ msg = string.format("Synchronizing hiders... (%.1fs)", syncDelay), ttl = math.max(1.0, syncDelay), icon = 'sync' })
            local t = 0
            scheduler.add(function(dt)
                t = t + (dt or 0)
                local pv = be:getPlayerVehicle(0)
                if pv and core_vehicleBridge and core_vehicleBridge.executeAction then
                    core_vehicleBridge.executeAction(pv, 'setFreeze', true)
                end
                if t >= syncDelay then
                    releaseSeekerForHunt()
                    return false
                end
                return true
            end)
        else
            releaseSeekerForHunt()
        end
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
                if scheduler and scheduler.add then
                    local delays = {0.4, 1.0, 2.0}
                    for _, delay in ipairs(delays) do
                        local t = 0
                        scheduler.add(function(dt)
                            t = t + (dt or 0)
                            if t >= delay then
                                if playerTeam == "hider" and allowDisguise and (not assignedPropName or assignedPropName == "") then
                                    TriggerServerEvent("PropHunt_requestState", "")
                                end
                                return false
                            end
                            return true
                        end)
                    end
                end
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

    -- Always clear any temp prop vehicles for this eliminated player on this client
    clearTempPropsForOwnerPid(targetId)
    pulseNicknameRenderer()

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

                    if cleanupTempSpawnSwapProps then
                        cleanupTempSpawnSwapProps()
                    end

                    if currentRoundId then localEliminatedRestoreRound = currentRoundId end
                    beamMessage({ msg = "You were found! Back to your car (eliminated).", ttl = 4, icon = 'directions_car' })

                else
                    -- Replace-mode fallback: rebuild original vehicle from captured model/config.
                    if preDisguiseModelKey and core_vehicles and core_vehicles.replaceVehicle then
                        local okRep, errRep = pcall(function()
                            if preDisguiseConfig and preDisguiseConfig ~= '' then
                                core_vehicles.replaceVehicle(preDisguiseModelKey, { config = preDisguiseConfig })
                            else
                                core_vehicles.replaceVehicle(preDisguiseModelKey, {})
                            end
                        end)
                        if okRep then
                            if currentRoundId then localEliminatedRestoreRound = currentRoundId end
                            beamMessage({ msg = "You were found! Reverting to car.", ttl = 4, icon = 'directions_car' })
                        else
                            print("WARN: replace fallback revert failed: " .. tostring(errRep))
                        end
                    else
                        print("WARN: No original vehicle captured; cannot revert")
                    end
                end
            end
        end
    end
end

onRoundEnd = function(data)
    -- data can contain a reason string from the server
    local reason = tostring(data or "")

    local skipRestore = (currentRoundId and localEliminatedRestoreRound == currentRoundId)

    -- Best-effort: restore original vehicle for hiders (spawn+deactivate disguise)
    if (not skipRestore) and originalVehId and be:getObjectByID(originalVehId) then
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
        pcall(function() ov:queueLuaCommand('electrics.setIgnitionLevel(3)') end)
        pcall(function()
            if core_vehicleBridge and core_vehicleBridge.executeAction then
                core_vehicleBridge.executeAction(ov, 'setFreeze', false)
            end
        end)
        pcall(function() be:enterVehicle(0, ov) end)
    elseif preDisguiseModelKey and core_vehicles and core_vehicles.replaceVehicle then
        -- Replace-mode fallback at round end
        local okRep, errRep = pcall(function()
            if preDisguiseConfig and preDisguiseConfig ~= '' then
                core_vehicles.replaceVehicle(preDisguiseModelKey, { config = preDisguiseConfig })
            else
                core_vehicles.replaceVehicle(preDisguiseModelKey, {})
            end
        end)
        if not okRep then
            print("WARN: round-end replace fallback failed: " .. tostring(errRep))
        end
    end

    -- Hard safety: in replace/fallback paths, force-restore local hider vehicle model once per round.
    if currentRoundId and roundEndRestoreAppliedRound == currentRoundId then
        -- duplicate round-end event; skip repeat restore
    elseif playerTeam == "hider" and preDisguiseModelKey and core_vehicles and core_vehicles.replaceVehicle then
        local function doRestoreReplace()
            local okRep, errRep = pcall(function()
                if preDisguiseConfig and preDisguiseConfig ~= '' then
                    core_vehicles.replaceVehicle(preDisguiseModelKey, { config = preDisguiseConfig })
                else
                    core_vehicles.replaceVehicle(preDisguiseModelKey, {})
                end
            end)
            if okRep then
                print("[PH] round-end forced restore -> " .. tostring(preDisguiseModelKey))
            else
                print("WARN: round-end forced restore failed: " .. tostring(errRep))
            end
        end

        doRestoreReplace()
        if currentRoundId then roundEndRestoreAppliedRound = currentRoundId end
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
    forceLocalVehicleVisible()
    if scheduler and scheduler.add then
        local t = 0
        scheduler.add(function(dt)
            t = t + (dt or 0)
            if t >= 0.25 then
                forceLocalVehicleVisible()
                return false
            end
            return true
        end)
    end

    if cleanupTempSpawnSwapProps then cleanupTempSpawnSwapProps() end
    pulseNicknameRenderer()
    postRoundCleanupUntil = os.clock() + 10.0
    lastPostRoundCleanupSweepAt = 0

    if currentRoundId then
        roundEndRestoreAppliedRound = currentRoundId
        gameEndRestoreAppliedRound = currentRoundId
    end

    assignedPropName = nil
    originalVehId = nil
    propVehId = nil
    preDisguiseModelKey = nil
    preDisguiseConfig = nil
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
    -- data: "roundId,seekerFadeDist,seekerFilterIntensity,hiderFadeDist,hiderFilterIntensity,disguiseMode,forceGhostOffOnRestore,spawnswapRetryCount,cleanupSweepSeconds"
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

    if #parts >= 7 then
        local b = tostring(parts[7] or ""):lower()
        forceGhostOffOnRestore = not (b == "false" or b == "0" or b == "off")
    end

    if #parts >= 8 then
        local n = tonumber(parts[8])
        if n then spawnswapRetryCount = math.max(1, math.floor(n)) end
    end

    if #parts >= 9 then
        local n = tonumber(parts[9])
        if n then cleanupSweepSeconds = math.max(1, math.floor(n)) end
    end

    if #parts >= 10 then
        local b = tostring(parts[10] or ""):lower()
        seekerTabPrevention = not (b == "false" or b == "0" or b == "off")
    end

    -- Optional (backward-compatible): hide nametags toggle, then moving reset controls.
    if #parts >= 11 then
        local b = tostring(parts[11] or ""):lower()
        hideNametagsInRound = not (b == "false" or b == "0" or b == "off")
    end

    if #parts >= 12 then
        local b = tostring(parts[12] or ""):lower()
        disableResetsWhenMoving = not (b == "false" or b == "0" or b == "off")
    end

    if #parts >= 13 then
        local v = tonumber(parts[13])
        if v then maxResetMovingSpeed = math.max(0, v) end
    end

    if #parts >= 14 then
        local b = tostring(parts[14] or ""):lower()
        allowNodeGrabInRound = (b == "true" or b == "1" or b == "on")
    end

    if #parts >= 15 then
        local b = tostring(parts[15] or ""):lower()
        allowHiderResetInRound = (b == "true" or b == "1" or b == "on")
    end

    -- Apply updated nametag preference immediately.
    pulseNicknameRenderer()

    preSpawnIfNeeded()
end

onHudPulse = function(data)
    local parts = {}
    for part in string.gmatch(tostring(data or ""), "[^,]+") do table.insert(parts, part) end
    if #parts < 8 then return end

    local rid = tonumber(parts[1])
    local phase = tostring(parts[2] or "idle")
    local alive = tonumber(parts[3] or 0) or 0
    local hiders = tonumber(parts[4] or 0) or 0
    local seekers = tonumber(parts[5] or 0) or 0
    local rTimer = tonumber(parts[6] or 0) or 0
    local hTimer = tonumber(parts[7] or 0) or 0
    local preset = tostring(parts[8] or "custom")

    if rid then currentRoundId = rid end

    local objective = (playerTeam == "seeker") and "Find and tag hiders" or "Survive and waste time"
    local msg = string.format("%s | H:%d/%d S:%d | %s | preset=%s", string.upper(phase), alive, hiders, seekers, objective, preset)
    if playerTeam == "hider" and currentRoundId and spawnswapDisabledRound == currentRoundId and spawnswapDisabledReason then
        msg = msg .. " | spawnswap=" .. tostring(spawnswapDisabledReason)
    end
    local key = msg .. "|" .. tostring(rTimer) .. "|" .. tostring(hTimer)

    local t = os.clock()
    if key ~= lastHudPulseKey and (t - lastHudPulseMsgAt) > 6 then
        lastHudPulseKey = key
        lastHudPulseMsgAt = t
        beamMessage({ msg = msg, ttl = 2.2, icon = 'flag' })
    end
end

onKillcamPulse = function(data)
    local rid, seekerName, hiderName = tostring(data or ""):match("^([^,]+),([^,]+),(.+)$")
    if rid and tonumber(rid) then currentRoundId = tonumber(rid) end
    if seekerName and seekerName ~= "" then
        beamMessage({ msg = "Tagged by " .. tostring(seekerName) .. " (" .. tostring(hiderName or "you") .. ")", ttl = 3.5, icon = 'movie' })
    end
end

onCooldownHint = function(data)
    local kind, rem = tostring(data or ""):match("^([^,]+),([^,]+)$")
    if kind == "scan" then
        local n = tonumber(rem or "0") or 0
        local pct = math.max(0, math.min(1, 1 - (n / 2.0)))
        local ring = (pct > 0.80 and "◉") or (pct > 0.60 and "◔") or (pct > 0.35 and "◑") or (pct > 0.10 and "◕") or "○"
        beamMessage({ msg = string.format("SCAN %s %.1fs", ring, n), ttl = 1.0, icon = 'timer' })
    end
end

onSpawnHint = function(data)
    local team, sx, sy, sz = tostring(data or ""):match("^([^,]+),([^,]+),([^,]+),([^,]+)$")
    if not team then return end
    beamMessage({ msg = string.format("%s spawn hint: %s, %s, %s", tostring(team), tostring(sx), tostring(sy), tostring(sz)), ttl = 4.0, icon = 'place' })
end

clearTempPropByServerString = function(targetServerVeh)
    if not targetServerVeh or targetServerVeh == "" then return end

    local pidStr, idxStr = tostring(targetServerVeh):match("^(%d+)%-(%d+)$")
    local idx = tonumber(idxStr)

    -- Global default: destructive clears are always allowed post-round.
    local allowDestructiveGlobal = (gameActive ~= true)

    -- 1) Best-effort remove from BeamMP vehicle registry (prevents stale nametags)
    -- Only run when destructive clear is allowed for this target.
    local shouldNotifyServerVehicleRemoved = false

    -- 2) Sweep matching vehicle data and scrub display metadata.
    if MPVehicleGE and MPVehicleGE.getVehicles then
        local list = MPVehicleGE.getVehicles() or {}
        for _, veh in pairs(list) do
            if tostring(veh.serverVehicleString or "") == targetServerVeh then
                local obj = be:getObjectByID(veh.gameVehicleID)
                local playerVeh = be:getPlayerVehicle(0)
                local playerVehId = playerVeh and playerVeh:getID() or nil

                -- In active rounds, allow destructive clear ONLY for temp spawn-swap entries (idx > 0)
                -- that are not currently the player's controlled vehicle.
                local allowDestructive = allowDestructiveGlobal
                if not allowDestructive then
                    local isTempEntry = (idx and idx > 0)
                    local isPlayerControlled = (playerVehId and veh.gameVehicleID and tonumber(veh.gameVehicleID) == tonumber(playerVehId))
                    allowDestructive = (isTempEntry == true and isPlayerControlled ~= true)
                end

                if allowDestructive and obj then
                    pcall(function() obj:setActive(0) end)
                    pcall(function()
                        if core_vehicleBridge and core_vehicleBridge.executeAction then
                            core_vehicleBridge.executeAction(obj, 'setFreeze', true)
                        end
                    end)
                    if idx and idx > 0 then
                        queueHardDelete(targetServerVeh, 2.5)
                    end
                    shouldNotifyServerVehicleRemoved = true
                end

            end
        end
    end

    if shouldNotifyServerVehicleRemoved and MPVehicleGE and MPVehicleGE.onServerVehicleRemoved then
        pcall(function() MPVehicleGE.onServerVehicleRemoved(targetServerVeh) end)
    end
end

clearTempPropsForOwnerPid = function(ownerPid)
    ownerPid = tonumber(ownerPid)
    if not ownerPid then return end
    if not MPVehicleGE or not MPVehicleGE.getVehicles then return end

    for _, veh in pairs(MPVehicleGE.getVehicles() or {}) do
        local svs = tostring(veh.serverVehicleString or "")
        local pidStr, idxStr = svs:match("^(%d+)%-(%d+)$")
        local pid = tonumber(pidStr)
        local idx = tonumber(idxStr)
        if pid and idx and pid == ownerPid and idx > 0 then
            clearTempPropByServerString(svs)
        end
    end
end

onTempPropClear = function(data)
    local targetServerVeh = tostring(data or "")
    if targetServerVeh == "" then return end
    clearTempPropByServerString(targetServerVeh)
    pulseNicknameRenderer()
end

onTempPropClearOwner = function(data)
    local ownerPid = tonumber(data)
    if not ownerPid then return end
    clearTempPropsForOwnerPid(ownerPid)
    pulseNicknameRenderer()
end


local function isCurrentControlledServerVehString(svs)
    if not svs or svs == "" then return false end
    local pv = be and be:getPlayerVehicle(0) or nil
    if not pv then return false end
    local pvid = pv:getID()
    if not pvid then return false end

    if MPVehicleGE and MPVehicleGE.getServerVehicleID then
        local ok, cur = pcall(function() return MPVehicleGE.getServerVehicleID(pvid) end)
        if ok and cur and tostring(cur) == tostring(svs) then
            return true
        end
    end

    if MPVehicleGE and MPVehicleGE.getVehicles then
        for _, v in pairs(MPVehicleGE.getVehicles() or {}) do
            if tonumber(v and v.gameVehicleID) == tonumber(pvid) then
                return tostring(v.serverVehicleString or "") == tostring(svs)
            end
        end
    end

    return false
end


onForceSync = function(data)
    -- data: "roundId,reason" (reason currently hide_end)
    local ridStr, why = tostring(data or ""):match("^%s*(%d+)%s*,%s*([^,]+)%s*$")
    local rid = tonumber(ridStr)
    if rid then currentRoundId = rid end

    -- IMPORTANT: only seekers perform forced sync burst at hide-end.
    -- Running this on hiders can trigger repeated state/edit churn and short freezes.
    if playerTeam == "seeker" then
        requestStateBurst()
        if TriggerServerEvent then
            pcall(function() TriggerServerEvent("PropHunt_requestState", "") end)
        end
    end

    print("[PH] force sync processed team=" .. tostring(playerTeam or "nil") .. " reason=" .. tostring(why or ""))
end

onTeamUpdate = function(data)
    -- data: "roundId,team"
    local roundStr, team = tostring(data or ""):match("^%s*(%d+)%s*,%s*(%w+)%s*$")
    if roundStr then currentRoundId = tonumber(roundStr) end
    if team and team ~= "" then
        playerTeam = team
        if team == "seeker" then
            -- Ensure nametags stay hidden when enabled.
            if shouldApplyNametagMaskNow() and MPVehicleGE and MPVehicleGE.hideNicknames then
                MPVehicleGE.hideNicknames(true)
            end
            local sv = be:getPlayerVehicle(0)
            seekerLockedVehId = sv and sv:getID() or seekerLockedVehId
            beamMessage({ msg = "You have been CONVERTED into a SEEKER!", ttl = 4, icon = 'visibility' })
        else
            -- Failsafe: if role switched away from seeker, force-clear seeker blackout effects.
            setSeekerVisualBlock(false)
            clearSeekerBlackoutFallback()
            beamMessage({ msg = "Team updated: " .. tostring(team), ttl = 3, icon = 'info' })
        end
    end
end

hardClearAllTempProps = function()
    if not MPVehicleGE or not MPVehicleGE.getVehicles then return end
    local cleared = 0
    for _, veh in pairs(MPVehicleGE.getVehicles() or {}) do
        local svs = tostring(veh.serverVehicleString or "")
        local pidStr, idxStr = string.match(svs, "^(%d+)%-(%d+)$")
        local pid = tonumber(pidStr)
        local idx = tonumber(idxStr)
        local isTemp = (pidStr and idx and idx > 0)
        if isTemp and not isCurrentControlledServerVehString(svs) then
            print('[PH] hard clear temp prop ' .. tostring(svs))
            clearTempPropByServerString(svs)
            cleared = cleared + 1
        end
    end
    if cleared > 0 then print('[PH] hard clear temp props count=' .. tostring(cleared)) end
    pulseNicknameRenderer()
end

cleanupTempSpawnSwapProps = function()
    -- Safety: never run owner-wide sweep while round is active.
    -- This sweep is intended for post-round stale cleanup only.
    if gameActive then return end

    local function doSweep()
        if not MPVehicleGE or not MPVehicleGE.getVehicles then return end

        local byOwner = {}
        for _, veh in pairs(MPVehicleGE.getVehicles() or {}) do
            local svs = tostring(veh.serverVehicleString or "")
            local pidStr, idxStr = string.match(svs, "^(%d+)%-(%d+)$")
            local pid = tonumber(pidStr)
            local idx = tonumber(idxStr)
            if pid and idx then
                byOwner[pid] = byOwner[pid] or {}
                table.insert(byOwner[pid], { svs = svs, idx = idx, isLocal = (veh.isLocal == true) })
            end
        end

        -- Round-end rule: always clear temp spawn-swap entries (idx > 0).
        -- Keep owner base vehicles (idx == 0) only.
        local changed = false
        for _, list in pairs(byOwner) do
            for _, v in ipairs(list) do
                local vidx = tonumber(v.idx) or -1
                local vpid = tonumber((tostring(v.svs):match("^(%d+)%-")))
                if vidx > 0 and not isCurrentControlledServerVehString(v.svs) then
                    clearTempPropByServerString(v.svs)
                    changed = true
                end
            end
        end
        if changed then pulseNicknameRenderer() end
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
    forceLocalVehicleVisible()
    requestStateBurst()
end
M.onPreRender = function(dt)
    if hidePhase and playerTeam == "seeker" then
        -- Last-frame hard override so nothing else can clear the blackout.
        forceSeekerBlackoutNow()
    end

    if gameActive then
        enforceSeekerHideTopCamera()
    end
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
        local rid = tonumber(currentRoundId or 0) or 0
        local token = makeTagToken(targetPlayerId)
        TriggerServerEvent("PropHunt_onContactReceive", tostring(rid) .. "|" .. tostring(targetPlayerId) .. "|" .. token)
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

local function makeTagToken(remotePid)
    return tostring(math.floor((os.clock() or 0) * 1000)) .. "-" .. tostring(remotePid or 0) .. "-" .. tostring(math.random(100000, 999999))
end

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
                local rid = tonumber(currentRoundId or 0) or 0
                local token = makeTagToken(remotePid)
                TriggerServerEvent("PropHunt_onContactReceive", tostring(rid) .. "|" .. tostring(remotePid) .. "|" .. token)
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