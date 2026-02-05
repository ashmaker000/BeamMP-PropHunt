-- lua/vehicle/extensions/auto/prophunt.lua
-- Vehicle-side coordinator for PropHunt. Calls collision detection when the game is running.

local M = {}

local gameRunning = false

local function setGameRunning(running)
  gameRunning = running and true or false
end

local function updateGFX()
  if not gameRunning then return end
  if prophuntcontactdetection and prophuntcontactdetection.checkForCollisions then
    prophuntcontactdetection.checkForCollisions()
  end
end

M.setGameRunning = setGameRunning
M.updateGFX = updateGFX

return M
