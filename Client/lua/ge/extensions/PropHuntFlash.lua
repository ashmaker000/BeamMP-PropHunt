-- lua/ge/extensions/PropHuntFlash.lua
local M = {}

-- --- CONFIG ---
local FLASH_RANGE = 300 -- match audible flashbang range (can be changed via /phconfig)
local SOUND_DISTANCE = 300
local SOUND_VOLUME = 1
local MAX_SOUND_LENGTH = 5

-- --- CONFIG SETTER ---
local function setFlashRange(newRange)
    FLASH_RANGE = newRange
    print("DEBUG: Flash effect range updated to " .. newRange .. " meters")
end

-- --- STATE ---
local flashIntensity = 0
local flashDuration = 0
local activeEmitters = {} -- Store sound emitters for flashbangs

-- --- VIGNETTE SUPPORT (for white flash effect) ---
local function ensureVignette()
    -- Try to load the vignette shader API if it isn't loaded yet
    if not (extensions and extensions.vignetteShaderAPI) then
        local ok, err = pcall(function() extensions.load("vignetteShaderAPI") end)
        if not ok then
            log('E', 'PropHuntFlash', 'Failed to load vignetteShaderAPI: ' .. tostring(err))
        end
    end
end

-- --- TRIGGER LOGIC ---
local function manualFlashbang()
    -- Ask the Core script who the Prop is
    if not extensions.PropHunt or not extensions.PropHunt.getPropID then 
        print("Error: PropHunt Core not found!")
        return 
    end

    local propID = extensions.PropHunt.getPropID()

    if not propID then return end
    local veh = be:getObjectByID(propID)
    if not veh then return end
    
    -- Send signal to vehicle
    veh:queueLuaCommand("electrics.values.phFlashbang = 1")
    
    -- Auto-reset the signal after 0.5s so we can use it again later
    veh:queueLuaCommand("local t = 0; local f = function(dt) t=t+dt; if t>0.5 then electrics.values.phFlashbang=0; return false end return true end; h=scheduler.add(f)")
end

-- --- RECEIVER LOGIC ---
local function handleFlashbang(sourceVehID, sourcePlayerID)
    -- VISUAL EFFECT ONLY (sound is handled by PropHunt.lua)
    -- NOTE: Server-side team filtering means this is only called for seekers
    -- No distance checking needed - server handles all filtering

    local playerVeh = be:getPlayerVehicle(0)
    if not playerVeh then
        print("DEBUG: No player vehicle found")
        return
    end

    -- Check if this is the owner triggering the flashbang
    if playerVeh:getID() == sourceVehID then
        -- Self-flash with shorter duration (0.5 seconds)
        flashIntensity = 1
        flashDuration = 0.5
        print("DEBUG: Self-flash triggered (0.5s)")
        return
    end

    -- Trigger full flash effect for other players (7-second blind)
    flashIntensity = 1
    flashDuration = 7.0
    print("DEBUG: You were flashed by player " .. tostring(sourcePlayerID) .. " (7s blind)")
end

-- --- UPDATE LOOP ---
local function onUpdate(dt)
    -- VISUAL LOGIC (VIGNETTE-BASED WHITE FLASH)
    if flashDuration > 0 then
        flashDuration = flashDuration - dt

        -- Make sure the vignette system is available
        ensureVignette()

        if extensions and extensions.vignetteShaderAPI then
            -- Strong white flash that fades out near the end.
            -- We fade alpha in the last 0.5 seconds of the effect.
            local alpha = 1
            if flashDuration < 0.5 then
                alpha = math.max(0, flashDuration / 0.5)
            end

            extensions.vignetteShaderAPI.setEnabled(true)
            extensions.vignetteShaderAPI.setColor(Point4F(1, 1, 1, alpha)) -- solid white flash
            extensions.vignetteShaderAPI.setInnerRadius(0)
            extensions.vignetteShaderAPI.setOuterRadius(0)
        end
    else
        -- Flash completed: reset vignette back to normal if it was active
        if flashIntensity > 0 then
            flashIntensity = 0
            ensureVignette()
            if extensions and extensions.vignetteShaderAPI then
                extensions.vignetteShaderAPI.resetVignette()
            end
        end
    end

    -- SOUND CLEANUP LOGIC (legacy code, not actively used since sound moved to PropHunt.lua)
    for vid, data in pairs(activeEmitters) do
        local emitter = scenetree.findObjectById(data.id)
        if emitter then
            data.timer = data.timer - dt
            if data.timer <= 0 then
                emitter:delete()
                activeEmitters[vid] = nil
            else
                -- Keep sound attached to moving car
                local veh = be:getObjectByID(vid)
                if veh then emitter:setPosition(veh:getPosition()) end
            end
        else
            activeEmitters[vid] = nil
        end
    end
end

-- --- NETWORK EVENT HANDLER (BeamMP) ---
-- Called when the server broadcasts a flashbang event to all clients.
local function onNetworkFlashbang(data)
    print("DEBUG: PropHuntFlash received network flashbang event: " .. tostring(data))
    
    -- data is expected to be the source vehicle ID as a string
    local vehID = tonumber(data)
    if not vehID then 
        print("DEBUG: Invalid vehicle ID in network flashbang")
        return 
    end

    -- Trigger the visual flash effect for all players (handleFlashbang will filter out owner)
    handleFlashbang(vehID)
end

-- --- EXTENSION LOADED ---
local function onExtensionLoaded()
    print("DEBUG: PropHuntFlash extension loaded")

    -- Preload vignetteShaderAPI so it's ready when needed
    if not (extensions and extensions.vignetteShaderAPI) then
        local ok, err = pcall(function() extensions.load("vignetteShaderAPI") end)
        if ok then
            print("DEBUG: vignetteShaderAPI loaded successfully")
        else
            print("ERROR: Failed to load vignetteShaderAPI: " .. tostring(err))
        end
    else
        print("DEBUG: vignetteShaderAPI already loaded")
    end

    -- NOTE: Network handler registration removed - PropHunt.lua now handles
    -- the "PropHunt_Flashbang" event and calls handleFlashbang() directly
    print("DEBUG: PropHuntFlash ready (visual effects handled via PropHunt.lua)")
end

-- --- EXPORTS ---
M.onExtensionLoaded = onExtensionLoaded
M.onUpdate = onUpdate
M.manualFlashbang = manualFlashbang
M.handleFlashbang = handleFlashbang
M.setFlashRange = setFlashRange

return M