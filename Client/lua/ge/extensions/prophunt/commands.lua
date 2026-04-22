local M = {}
M.BUILD = "2026-02-11-phase2e"

local function resolveMapKey()
  if not map or not map.getMap then return "unknown" end

  local ok, mapData = pcall(function() return map.getMap() end)
  if not ok or type(mapData) ~= "table" then return "unknown" end

  local candidates = {
    mapData.misFilePath,
    mapData.levelName,
    mapData.name,
    mapData.id,
  }

  for _, raw in ipairs(candidates) do
    local text = tostring(raw or "")
    if text ~= "" then
      local token = text:match("levels[/\\]([^/\\]+)")
        or text:match("^/levels/([^/\\]+)")
        or text:match("^levels[/\\]([^/\\]+)")
        or text:match("([^/\\]+)$")
      if token and token ~= "" then
        return tostring(token):lower()
      end
    end
  end

  return "unknown"
end

local function getPlayerVehicleSnapshot()
  if not be or not be.getPlayerVehicle then
    return nil, "Player vehicle API unavailable"
  end

  local veh = be:getPlayerVehicle(0)
  if not veh then
    return nil, "No player vehicle"
  end

  local pos = veh.getPosition and veh:getPosition() or nil
  local rot = veh.getRotation and veh:getRotation() or nil
  if not pos then
    return nil, "Vehicle position unavailable"
  end

  return {
    mapKey = resolveMapKey(),
    pos = pos,
    rot = rot,
    vehId = veh.getID and veh:getID() or nil,
  }, nil
end

function M.handleChatMessage(msg, ctx)
  local colonIndex = string.find(msg, ":")
  if not colonIndex then return end

  local message = string.sub(msg, colonIndex + 1, -1)
  if not message:match("^/ph") then return end

  local args = {}
  for word in message:gmatch("%S+") do table.insert(args, word) end

  local cmd = args[1]
  local argsSummary = table.concat(args, " ")
  ctx.logCommandUsage(cmd, argsSummary)

  if cmd == "/ph" and #args >= 3 and ctx.getClientSettingKey(args[2]) then
    table.remove(args, 1)
    table.insert(args, 1, "/phconfig")
    cmd = "/phconfig"
  end

  if cmd == "/phconfig" then
    if #args < 3 then
      ctx.beamMessage({
        msg = "Usage: /phconfig <setting> <value>\nSettings: taunt_dist, proximity, proximity_dist, hiderfadedist, hiderfilterintensity",
        ttl = 5,
        icon = 'info'
      })
      return
    end

    local settingKey = ctx.getClientSettingKey(args[2])
    local value = tonumber(args[3])

    if not value or not settingKey then
      local hint = "taunt_dist, proximity, proximity_dist, hiderfadedist, hiderfilterintensity"
      ctx.beamMessage({ msg = "Unknown setting or invalid value. Available: " .. hint, ttl = 5, icon = 'error' })
      return
    end

    if settingKey == "taunt_dist" then
      ctx.setTauntDistance(math.max(0, value))
      ctx.beamMessage({ msg = "Taunt sound distance set to " .. tostring(ctx.getTauntDistance()) .. " meters", ttl = 3, icon = 'check' })
    elseif settingKey == "proximity" then
      ctx.setSeekerFilterIntensity(math.max(0, math.min(1, value)))
      ctx.beamMessage({ msg = string.format("Seeker proximity intensity set to %.2f", ctx.getSeekerFilterIntensity()), ttl = 3, icon = 'check' })
    elseif settingKey == "proximity_dist" then
      ctx.setSeekerFadeDist(math.max(5, value))
      ctx.beamMessage({ msg = "Seeker proximity range set to " .. tostring(ctx.getSeekerFadeDist()) .. " meters", ttl = 3, icon = 'check' })
    elseif settingKey == "hider_fade" then
      ctx.setHiderFadeDist(math.max(5, value))
      ctx.beamMessage({ msg = "Hider proximity range set to " .. tostring(ctx.getHiderFadeDist()) .. " meters", ttl = 3, icon = 'check' })
    elseif settingKey == "hider_intensity" then
      ctx.setHiderFilterIntensity(math.max(0, math.min(1, value)))
      ctx.beamMessage({ msg = string.format("Hider proximity intensity set to %.2f", ctx.getHiderFilterIntensity()), ttl = 3, icon = 'check' })
    end
  elseif cmd == "/phtag" then
    if #args < 2 then
      ctx.beamMessage({ msg = "Usage: /phtag <playerId> (seekers only)", ttl = 5, icon = 'info' })
      return
    end

    local targetId = tonumber(args[2])
    if not targetId then
      ctx.beamMessage({ msg = "Error: playerId must be a number", ttl = 3, icon = 'error' })
      return
    end

    if TriggerServerEvent then
      local rid = 0
      if ctx.getCurrentRoundId then
        local cur = tonumber(ctx.getCurrentRoundId())
        if cur then rid = cur end
      end
      local token = tostring(math.floor((os.clock() or 0) * 1000)) .. "-" .. tostring(math.random(100000, 999999))
      TriggerServerEvent("PropHunt_TagRequest", tostring(rid) .. "|" .. tostring(targetId) .. "|" .. token)
      ctx.beamMessage({ msg = "Tag request sent for player " .. tostring(targetId), ttl = 2, icon = 'near_me' })
    else
      ctx.beamMessage({ msg = "Error: TriggerServerEvent not available", ttl = 3, icon = 'error' })
    end
  elseif cmd == "/phhelp" then
    ctx.beamMessage({
      msg = "PropHunt Commands (canonical):\n" ..
            "/ph config <setting> <value> - Configure client distances\n" ..
            "Settings: taunt_dist, proximity, proximity_dist, hiderfadedist, hiderfilterintensity\n" ..
            "/phtag <playerId> - (seekers) send tag request\n" ..
            "/phhere - Show current map/coords for spawn-bank setup",
      ttl = 9,
      icon = 'help'
    })
  elseif cmd == "/phhere" or cmd == "/phcoords" then
    local snap, err = getPlayerVehicleSnapshot()
    if not snap then
      ctx.beamMessage({ msg = "PropHunt location error: " .. tostring(err), ttl = 4, icon = 'error' })
      return
    end

    local pos = snap.pos
    local rot = snap.rot
    local mapKey = tostring(snap.mapKey or "unknown")
    local xyz = string.format("%.2f %.2f %.2f", tonumber(pos.x) or 0, tonumber(pos.y) or 0, tonumber(pos.z) or 0)
    local rotText = rot and string.format("%.4f %.4f %.4f %.4f", tonumber(rot.x) or 0, tonumber(rot.y) or 0, tonumber(rot.z) or 0, tonumber(rot.w) or 1) or "n/a"
    local seekerCmd = string.format("/ph spawnbank add %s seeker %.2f %.2f %.2f", mapKey, tonumber(pos.x) or 0, tonumber(pos.y) or 0, tonumber(pos.z) or 0)
    local hiderCmd = string.format("/ph spawnbank add %s hider %.2f %.2f %.2f", mapKey, tonumber(pos.x) or 0, tonumber(pos.y) or 0, tonumber(pos.z) or 0)

    ctx.beamMessage({
      msg = string.format("Map=%s\nXYZ=%s\nRot=%s", mapKey, xyz, rotText),
      ttl = 8,
      icon = 'place'
    })

    print("[PH] location map=" .. mapKey .. " xyz=" .. xyz .. " rot=" .. rotText .. " vehId=" .. tostring(snap.vehId or "n/a"))
    print("[PH] spawnbank seeker => " .. seekerCmd)
    print("[PH] spawnbank hider  => " .. hiderCmd)
  end
end

return M
