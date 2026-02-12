local M = {}
M.BUILD = "2026-02-11-phase2e"

function M.new(ctx)
  local self = {}
  local hiderIdSet = {}
  local seekerIdSet = {}

  function self.pidIsSeeker(pid)
    if not pid then return false end
    if seekerIdSet and seekerIdSet[pid] then return true end
    if not seekerIdSet or not next(seekerIdSet) then
      if hiderIdSet and hiderIdSet[pid] then return false end
      return true
    end
    return false
  end

  function self.pidIsHider(pid)
    if not pid then return false end
    if hiderIdSet and hiderIdSet[pid] then return true end
    if not hiderIdSet or not next(hiderIdSet) then
      if seekerIdSet and seekerIdSet[pid] then return false end
      return true
    end
    return false
  end

  function self.onHiderList(data)
    hiderIdSet = {}
    local parts = {}
    for part in string.gmatch(tostring(data or ""), "[^,]+") do table.insert(parts, part) end
    if #parts >= 1 then
      local rid = tonumber(parts[1])
      if rid and ctx.setRoundId then ctx.setRoundId(rid) end
    end
    for i = 2, #parts do
      local pid = tonumber(parts[i])
      if pid then hiderIdSet[pid] = true end
    end
    print("DEBUG: Received hider list (" .. tostring(#parts - 1) .. " hiders)")
  end

  function self.onSeekerList(data)
    seekerIdSet = {}
    local parts = {}
    for part in string.gmatch(tostring(data or ""), "[^,]+") do table.insert(parts, part) end
    if #parts >= 1 then
      local rid = tonumber(parts[1])
      if rid and ctx.setRoundId then ctx.setRoundId(rid) end
    end
    for i = 2, #parts do
      local pid = tonumber(parts[i])
      if pid then seekerIdSet[pid] = true end
    end
  end

  function self.resolveOwnerPlayerIdFromVehId(vehId)
    if not vehId then return nil end

    if MPVehicleGE and MPVehicleGE.getServerVehicleID then
      local ok, serverVeh = pcall(function() return MPVehicleGE.getServerVehicleID(vehId) end)
      if ok and serverVeh then
        local pid = string.match(tostring(serverVeh), "(%d+)%-%d+")
        if pid then return tonumber(pid) end
      end
    end

    local candidates = {
      function() if MPVehicleGE and MPVehicleGE.getOwnerID then return MPVehicleGE.getOwnerID(vehId) end end,
      function() if MPVehicleGE and MPVehicleGE.getVehicleOwner then return MPVehicleGE.getVehicleOwner(vehId) end end,
      function() if MPVehicleGE and MPVehicleGE.getOwner then return MPVehicleGE.getOwner(vehId) end end,
      function() if MPGameNetwork and MPGameNetwork.getVehicleOwner then return MPGameNetwork.getVehicleOwner(vehId) end end,
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

  function self.getNearestHiderDistance()
    local myVeh = be:getPlayerVehicle(0)
    if not myVeh then return nil end
    local myPos = myVeh:getPosition()
    if not myPos then return nil end
    local best = nil
    if not MPVehicleGE or not MPVehicleGE.getVehicles then return nil end

    for _, sv in pairs(MPVehicleGE.getVehicles()) do
      local vid = sv.gameVehicleID
      if vid and myVeh:getID() ~= vid then
        local pid = nil
        if sv.serverVehicleString then pid = tonumber(string.match(tostring(sv.serverVehicleString), "(%d+)%-%d+")) end
        if not pid then pid = self.resolveOwnerPlayerIdFromVehId(vid) end
        if pid and self.pidIsHider(pid) then
          local v = be:getObjectByID(vid)
          if v and v.getPosition then
            local p = v:getPosition()
            if p then
              local dx, dy, dz = (p.x-myPos.x), (p.y-myPos.y), (p.z-myPos.z)
              local d = math.sqrt(dx*dx + dy*dy + dz*dz)
              if not best or d < best then best = d end
            end
          end
        end
      end
    end
    return best
  end

  function self.getNearestSeekerDistance()
    local myVeh = be:getPlayerVehicle(0)
    if not myVeh then return nil, {} end
    local myPos = myVeh:getPosition()
    if not myPos then return nil, {} end
    local best, bestPid, bestVid = nil, nil, nil
    if not MPVehicleGE or not MPVehicleGE.getVehicles then return nil, {} end

    for _, sv in pairs(MPVehicleGE.getVehicles()) do
      local vid = sv.gameVehicleID
      if vid and myVeh:getID() ~= vid then
        local pid = nil
        if sv.serverVehicleString then pid = tonumber(string.match(tostring(sv.serverVehicleString), "(%d+)%-%d+")) end
        if not pid then pid = self.resolveOwnerPlayerIdFromVehId(vid) end
        if pid and self.pidIsSeeker(pid) then
          local v = be:getObjectByID(vid)
          if v and v.getPosition then
            local p = v:getPosition()
            if p then
              local dx, dy, dz = (p.x-myPos.x), (p.y-myPos.y), (p.z-myPos.z)
              local d = math.sqrt(dx*dx + dy*dy + dz*dz)
              if not best or d < best then best, bestPid, bestVid = d, pid, vid end
            end
          end
        end
      end
    end

    if best then
      return best, { pid = bestPid, vid = bestVid, dist = best, name = ctx.hunterNameForPid and ctx.hunterNameForPid(bestPid) or nil }
    end
    return nil, {}
  end

  return self
end

return M
