local M = {}
M.BUILD = "2026-02-11-phase2e"

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
      TriggerServerEvent("PropHunt_TagRequest", tostring(targetId))
      ctx.beamMessage({ msg = "Tag request sent for player " .. tostring(targetId), ttl = 2, icon = 'near_me' })
    else
      ctx.beamMessage({ msg = "Error: TriggerServerEvent not available", ttl = 3, icon = 'error' })
    end
  elseif cmd == "/phhelp" then
    ctx.beamMessage({
      msg = "PropHunt Commands:\n" ..
            "/phconfig <setting> <value> - Configure client distances\n" ..
            "Settings: taunt_dist, proximity, proximity_dist, hiderfadedist, hiderfilterintensity\n" ..
            "/phtag <playerId> - (seekers) tag a hider (temporary until automatic tagging)",
      ttl = 9,
      icon = 'help'
    })
  end
end

return M
