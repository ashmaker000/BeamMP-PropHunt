-- lua/ge/extensions/PropHuntKeybinds.lua
-- Helper extension so all Prop Hunt actions can be bound in Controls as lua commands.

local M = {}
local triedLoadAt = 0

local function ensurePropHuntLoaded()
    local ph = extensions and extensions.PropHunt or nil
    if ph and type(ph.manualTaunt) == "function" and type(ph.manualScan) == "function" then
        return ph
    end

    local now = os.clock and os.clock() or 0
    if (now - triedLoadAt) < 1.0 then return ph end
    triedLoadAt = now

    if extensions and extensions.load then
        local ok, err = pcall(function() extensions.load("PropHunt") end)
        if not ok then
            print("ERROR: failed to load PropHunt extension: " .. tostring(err))
        end
    end

    ph = extensions and extensions.PropHunt or ph
    if not (ph and type(ph.manualTaunt) == "function") then
        local ok, mod = pcall(require, "ge.extensions.prophunt.core")
        if not ok or not mod then
            ok, mod = pcall(require, "ge/extensions/prophunt/core")
        end
        if ok and mod then
            ph = mod
            if extensions then extensions.PropHunt = mod end
            if type(mod.onExtensionLoaded) == "function" then
                pcall(function() mod.onExtensionLoaded() end)
            end
            print("DEBUG: PropHuntKeybinds directly loaded PropHunt core fallback")
        else
            print("ERROR: direct PropHunt core load failed: " .. tostring(mod))
        end
    end

    if ph and type(ph.requestStateBurst) == "function" then
        pcall(function() ph.requestStateBurst() end)
    end
    return ph
end

local function safeCall(fnName)
    local ph = ensurePropHuntLoaded()
    if not ph then
        print("ERROR: PropHunt extension not loaded!")
        return
    end
    local fn = ph[fnName]
    if type(fn) == "function" then
        fn()
    else
        print("ERROR: PropHunt." .. fnName .. " is not a function!")
    end
end

local function setRunner()
    safeCall("setRunner")
end

local function setProp()
    safeCall("setProp")
end

local function performSwap()
    safeCall("performSwap")
end

local function taunt()
    safeCall("manualTaunt")
end

local function scan()
    safeCall("manualScan")
end

local function onExtensionLoaded()
    print("DEBUG: PropHuntKeybinds extension loaded")
    ensurePropHuntLoaded()
end

local function onUpdate(dt)
    ensurePropHuntLoaded()
end

M.onExtensionLoaded = onExtensionLoaded
M.onUpdate = onUpdate
M.setRunner = setRunner
M.setProp = setProp
M.performSwap = performSwap
M.taunt = taunt
M.scan = scan

return M
