-- lua/ge/extensions/PropHuntKeybinds.lua
-- Helper extension so all Prop Hunt actions can be bound in Controls as lua commands.

local M = {}

local function safeCall(fnName)
    if not extensions or not extensions.PropHunt then
        print("ERROR: PropHunt extension not loaded!")
        return
    end
    local fn = extensions.PropHunt[fnName]
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
end

M.onExtensionLoaded = onExtensionLoaded
M.setRunner = setRunner
M.setProp = setProp
M.performSwap = performSwap
M.taunt = taunt
M.scan = scan

return M
