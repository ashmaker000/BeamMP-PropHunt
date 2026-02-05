-- lua/vehicle/extensions/auto/prophuntcontactdetection.lua
-- Collision detection for PropHunt (modeled after Outbreak's outbreakcontactdetection.lua)

local M = {}

local vehicleID = obj:getId()
local carLength = obj:getInitialLength()
local vehiclePosition = obj:getCenterPosition()

local didProbe = false

local function checkForCollisions()
  if carLength == 0 then
    carLength = obj:getInitialLength()
  end

  -- One-time probe: what APIs do we have in vehicle Lua?
  if not didProbe then
    didProbe = true
    local okLen, len = pcall(function() return obj:getInitialLength() end)
    local okH, h = pcall(function() return obj:getInitialHeight() end)
    print(string.format("[PropHuntContact] self id=%s len=%s height=%s", tostring(vehicleID), tostring(okLen and len or 'nil'), tostring(okH and h or 'nil')))
    print(string.format("[PropHuntContact] has getObjectInitialWidth=%s getObjectInitialHeight=%s getObjectRotation=%s getObjectDirectionVector=%s", tostring(obj.getObjectInitialWidth), tostring(obj.getObjectInitialHeight), tostring(obj.getObjectRotation), tostring(obj.getObjectDirectionVector)))
  end

  local function safeVec3(v)
    if type(v) == 'table' and v.x then return vec3(v.x, v.y, v.z) end
    if type(v) == 'userdata' then return vec3(v) end
    return vec3(0,0,0)
  end

  local function getLenHgtWdt(otherId)
    local len = nil
    local hgt = nil
    local wdt = nil
    if otherId == nil then
      len = obj:getInitialLength()
      hgt = obj.getInitialHeight and obj:getInitialHeight() or nil
      wdt = obj.getInitialWidth and obj:getInitialWidth() or nil
    else
      len = obj:getObjectInitialLength(otherId)
      if obj.getObjectInitialHeight then
        pcall(function() hgt = obj:getObjectInitialHeight(otherId) end)
      end
      if obj.getObjectInitialWidth then
        pcall(function() wdt = obj:getObjectInitialWidth(otherId) end)
      end
    end

    len = tonumber(len) or 4.5
    hgt = tonumber(hgt) or 1.7
    wdt = tonumber(wdt) or math.min(2.2, math.max(1.2, len * 0.45))
    return len, hgt, wdt
  end

  local function getForward(otherId)
    -- Prefer true direction vectors if exposed
    if otherId == nil then
      if obj.getDirectionVector then
        local ok, dv = pcall(function() return obj:getDirectionVector() end)
        if ok and dv then return safeVec3(dv):normalized() end
      end
    else
      if obj.getObjectDirectionVector then
        local ok, dv = pcall(function() return obj:getObjectDirectionVector(otherId) end)
        if ok and dv then return safeVec3(dv):normalized() end
      end
    end
    -- Fallback: world forward
    return vec3(0,1,0)
  end

  local function getOBB(otherId)
    local c
    if otherId == nil then
      c = safeVec3(obj:getCenterPosition())
    else
      c = safeVec3(obj:getObjectCenterPosition(otherId))
    end

    local len, hgt, wdt = getLenHgtWdt(otherId)

    local fwd = getForward(otherId)
    local up = vec3(0,0,1)
    local right = fwd:cross(up)
    if right:squaredLength() < 1e-6 then
      right = vec3(1,0,0)
    else
      right:normalize()
    end

    -- axes scaled by half-extents
    local x = right * (wdt * 0.5)
    local y = fwd * (len * 0.5)
    local z = up * (hgt * 0.5)

    return c, x, y, z, len
  end

  -- Skip remote vehicles
  if v and v.mpVehicleType == "R" then return end

  if next(mapmgr.objectCollisionIds) ~= nil then
    vehiclePosition:set(obj:getCenterPosition())

    -- Build our own OBB once
    local c1, x1, y1, z1, len1 = getOBB(nil)

    for _, vehID in pairs(mapmgr.objectCollisionIds) do
      -- Quick distance gate for perf
      local otherCenter = obj:getObjectCenterPosition(vehID)
      local distance = vehiclePosition:distance(otherCenter)
      local len2 = obj:getObjectInitialLength(vehID) or 0
      local gate = ((tonumber(len2) + tonumber(len1)) / 2) * 1.25
      if distance < gate then
        local shouldTag = false

        if type(overlapsOBB_OBB) == 'function' then
          local c2, x2, y2, z2 = getOBB(vehID)
          -- True OBB overlap check (SAT)
          shouldTag = overlapsOBB_OBB(c1, x1, y1, z1, c2, x2, y2, z2)
        else
          -- Fallback to old behavior
          shouldTag = distance < ((obj:getObjectInitialLength(vehID) + carLength) / 2) * 1.1
        end

        if shouldTag then
          obj:queueGameEngineLua("if extensions and extensions.PropHunt and extensions.PropHunt.sendTagContact then extensions.PropHunt.sendTagContact("..vehID..","..vehicleID..") end")
        end
      end
    end
  end
end

M.checkForCollisions = checkForCollisions
return M
