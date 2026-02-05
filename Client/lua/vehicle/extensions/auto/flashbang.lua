-- lua/vehicle/extensions/auto/flashbang.lua
-- Per-vehicle auto extension that lets the UI trigger a flashbang.
-- Called from UI with:
--   bngApi.activeObjectLua("if extensions.auto_flashbang then extensions.auto_flashbang.trigger() end")

local M = {}

-- You can tweak these if you want cooldowns etc.
local COOLDOWN = 0.0   -- seconds, set >0 if you want to prevent spamming
local lastTriggerTime = -1

local function onReset()
  lastTriggerTime = -1
end

local function updateGFX(dt)
  -- nothing needed for now
end

local function trigger()
  -- Safety: ensure we have a vehicle object
  if not obj then return end

  -- Optional cooldown
  if COOLDOWN > 0 then
    local t = obj:getSimTime() or 0
    if lastTriggerTime > 0 and (t - lastTriggerTime) < COOLDOWN then
      return
    end
    lastTriggerTime = t
  end

  local vehId = obj:getID() or -1
  if vehId < 0 then return end

  -- 1) Local audio + network broadcast via PropHunt
  -- (manualFlashSound handles both local sound and multiplayer network request)
  obj:queueGameEngineLua(string.format([[
if extensions and extensions.PropHunt and extensions.PropHunt.manualFlashSound then
  extensions.PropHunt.manualFlashSound(%d)
end
]], vehId))
end

-- EXPORTS (these names are what BeamNG looks for)
M.onReset   = onReset
M.updateGFX = updateGFX
M.trigger   = trigger   -- <<< key function

return M
