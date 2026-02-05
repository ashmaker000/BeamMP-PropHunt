-- lua/vehicle/extensions/auto/PropHuntAudio.lua
local M = {}

local lastTauntPath = ""

local function updateGFX(dt)
    -- TAUNT LOGIC (Send to PropHunt.lua)
    local currentTaunt = electrics.values.phTaunt or ""
    if currentTaunt ~= "" and currentTaunt ~= lastTauntPath then
        obj:queueGameEngineLua(string.format(
            "if extensions.PropHunt then extensions.PropHunt.playSound('%s', %d) end",
            currentTaunt, obj:getID()
        ))
        lastTauntPath = currentTaunt
    elseif currentTaunt == "" then
        lastTauntPath = ""
    end

    -- FLASHBANG REMOVED - Now handled by flashbang.lua via network events
end

M.updateGFX = updateGFX
return M