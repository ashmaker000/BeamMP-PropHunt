-- lua/vehicle/extensions/auto/prophunt_tagger.lua
-- Auto extension: detects collisions on the local player's vehicle and forwards them to GE-side PropHunt.
-- Intended for seekers: collision tagging.

local M = {}

local lastSentTime = -1
local LOCAL_COOLDOWN = 0.25 -- seconds; server also enforces

local function now()
  -- getSimTime is per-vehicle sim time; good enough for local spam guard
  if obj and obj.getSimTime then return obj:getSimTime() or 0 end
  return 0
end

local function extractOtherId(c)
  if type(c) ~= 'table' then return nil end
  -- BeamNG collision callbacks vary; try common keys
  return c.otherObjectID or c.otherId or c.otherID or c.id2 or c.idB
end

local function onCollision(c)
  local otherId = extractOtherId(c)
  if not otherId then return end

  local t = now()
  if lastSentTime > 0 and (t - lastSentTime) < LOCAL_COOLDOWN then return end
  lastSentTime = t

  -- Forward to GE; PropHunt will decide if this should become a tag request.
  obj:queueGameEngineLua(string.format([[
if extensions and extensions.PropHunt and extensions.PropHunt.onSeekerCollision then
  extensions.PropHunt.onSeekerCollision(%d)
end
]], tonumber(otherId)))
end

M.onCollision = onCollision
return M
