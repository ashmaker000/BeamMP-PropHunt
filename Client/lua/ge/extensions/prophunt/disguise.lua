local M = {}
M.BUILD = "2026-02-11-phase2e"

local EXCLUDED = {
  flipramp = true,
  kickplate = true,
  large_angletester = true,
  large_bridge = true,
  large_cannon = true,
  large_crusher = true,
  large_hamster_wheel = true,
  large_roller = true,
  large_spinner = true,
  metal_ramp = true,
  weightpad = true,
  suspensionbridge = true,
  rollover = true,
}

local function isExcluded(key)
  return EXCLUDED[tostring(key)] == true
end

local function pickRandomPropModelKey()
  local ok, ml = pcall(function() return core_vehicles.getModelList(true) end)
  if not ok or not ml or not ml.models then return nil end
  local models = ml.models
  if #models == 0 then return nil end

  local attempts = 0
  local chosen
  repeat
    attempts = attempts + 1
    chosen = models[math.random(1, #models)]
  until (chosen and chosen.Type == 'Prop' and not isExcluded(chosen.key)) or attempts > 500

  if chosen and chosen.Type == 'Prop' and not isExcluded(chosen.key) then
    return chosen.key, chosen.Name
  end
  return nil
end

local function pickRandomPropConfig(modelKey)
  if not core_vehicles or not core_vehicles.getConfigList then return nil end
  local ok, list = pcall(function() return core_vehicles.getConfigList(true) end)
  if not ok or not list or not list.configs then return nil end

  local configs = {}
  for _, v in pairs(list.configs) do
    if v.model_key == modelKey then table.insert(configs, v) end
  end
  if #configs == 0 then return nil end

  local c = configs[math.random(#configs)]
  return c and c.key or nil
end

local function snapshotVehicleIds()
  local set = {}
  local list = scenetree.findClassObjects('BeamNGVehicle') or {}
  for _, name in ipairs(list) do
    local v = scenetree.findObject(name)
    if v and v.getID then set[v:getID()] = true end
  end
  return set
end

local function findNewVehicleId(before)
  local list = scenetree.findClassObjects('BeamNGVehicle') or {}
  for _, name in ipairs(list) do
    local v = scenetree.findObject(name)
    if v and v.getID then
      local id = v:getID()
      if not before[id] then return id end
    end
  end
  return nil
end


local function countOwnedVehicles()
  if not MPVehicleGE or not MPVehicleGE.getOwnMap then return 0 end
  local ok, ownMap = pcall(function() return MPVehicleGE.getOwnMap() end)
  if not ok or type(ownMap) ~= 'table' then return 0 end
  local c = 0
  for _, v in pairs(ownMap) do
    if v == true then c = c + 1 end
  end
  return c
end

local function spawnswapGuardAllows(ctx)
  local maxOwned = 2 -- keep one driver + one temp prop max
  local owned = countOwnedVehicles()
  if owned >= maxOwned then
    if ctx and ctx.disableSpawnswapForRound then
      pcall(function() ctx.disableSpawnswapForRound('vehicle_cap_guard') end)
    end
    return false
  end
  return true
end

local function ensureModelAndLabel(propName)
  local modelKey = propName
  local modelLabel = propName
  if tostring(propName) == "random" or tostring(propName) == "" or tostring(propName) == "nil" then
    local k, name = pickRandomPropModelKey()
    if not k then return nil, nil, "no prop models found" end
    modelKey = k
    modelLabel = name or k
  end
  return modelKey, modelLabel
end

local function capturePreDisguise(ctx)
  local curVehId = be:getPlayerVehicleID(0)
  if not curVehId then return end

  local modelKey = nil
  local cfgKey = nil

  if extensions and extensions.core_vehicle_manager and extensions.core_vehicle_manager.getVehicleData then
    local ok, vd = pcall(function() return extensions.core_vehicle_manager.getVehicleData(curVehId) end)
    if ok and vd and vd.config then
      if vd.config.model and vd.config.model ~= '' then modelKey = vd.config.model end
      if vd.config.partConfigFilename and vd.config.partConfigFilename ~= '' then cfgKey = vd.config.partConfigFilename end
    end
  end

  if (not modelKey or modelKey == '') and MPVehicleGE and MPVehicleGE.getVehicleByGameID then
    local v = MPVehicleGE.getVehicleByGameID(curVehId)
    if v and v.jbeam then modelKey = v.jbeam end
    if (not cfgKey or cfgKey == '') and v and v.partConfigFilename then cfgKey = v.partConfigFilename end
  end

  if ctx and ctx.setPreDisguiseModelKey and modelKey and modelKey ~= '' then
    pcall(function() ctx.setPreDisguiseModelKey(modelKey) end)
  end
  if ctx and ctx.setPreDisguiseConfig and cfgKey and cfgKey ~= '' then
    pcall(function() ctx.setPreDisguiseConfig(cfgKey) end)
  end
end

local function spawnPropVehicle(modelKey)
  local cfgKey = pickRandomPropConfig(modelKey)
  local before = snapshotVehicleIds()
  local okSpawn, errSpawn = pcall(function()
    if cfgKey then
      core_vehicles.spawnNewVehicle(modelKey, { config = cfgKey })
    else
      core_vehicles.spawnNewVehicle(modelKey, {})
    end
  end)
  if not okSpawn then return nil, errSpawn end

  local newId = findNewVehicleId(before)
  if not newId then return nil, "spawned vehicle id not found" end
  return newId, nil
end

local function reportTempPropServerString(ctx, gameVehId, retrySeconds, roundId)
  if not TriggerServerEvent or not MPVehicleGE or not gameVehId then return false end

  local function authorityFailed(reason)
    if ctx and ctx.disableSpawnswapForRound then
      pcall(function() ctx.disableSpawnswapForRound(reason or "authority_failed") end)
    end
  end

  local function trySend()
    local serverVeh = nil
    if MPVehicleGE.getVehicles then
      for _, veh in pairs(MPVehicleGE.getVehicles() or {}) do
        if tonumber(veh.gameVehicleID) == tonumber(gameVehId) then
          serverVeh = tostring(veh.serverVehicleString or "")
          break
        end
      end
    end
    if (not serverVeh or serverVeh == "") and MPVehicleGE.getServerVehicleID then
      local ok, sv = pcall(function() return MPVehicleGE.getServerVehicleID(gameVehId) end)
      if ok and sv then serverVeh = tostring(sv) end
    end
    if serverVeh and serverVeh ~= "" then
      local rid = tonumber(roundId)
      if rid then
        TriggerServerEvent("PropHunt_tempPropSet", string.format("%d|%s", rid, serverVeh))
      else
        TriggerServerEvent("PropHunt_tempPropSet", serverVeh)
      end
      return true
    end
    return false
  end

  if trySend() then return true end
  if scheduler and scheduler.add then
    local waited, maxWait = 0, (tonumber(retrySeconds) or 2.0)
    scheduler.add(function(dt)
      waited = waited + (dt or 0)
      if trySend() then return false end
      if waited >= maxWait then
        authorityFailed("no_server_vehicle_id")
        return false
      end
      return true
    end)
    return false
  end

  -- If scheduler is unavailable, do not hard-disable this round here.
  -- Let caller decide/fallback at disguise time.
  return false
end

local function stashVehicleFarAway(veh, refPos, refRot)
  if not veh or not refPos then return end
  local x = refPos.x + 5000
  local y = refPos.y + 5000
  local z = refPos.z + 20
  local rx, ry, rz, rw = 0, 0, 0, 1
  if refRot then
    rx, ry, rz, rw = refRot.x, refRot.y, refRot.z, refRot.w
  end
  if veh.setPositionRotation then
    pcall(function() veh:setPositionRotation(x, y, z, rx, ry, rz, rw) end)
  end
  pcall(function() veh:queueLuaCommand('electrics.setIgnitionLevel(0)') end)
  pcall(function()
    if core_vehicleBridge and core_vehicleBridge.executeAction then
      core_vehicleBridge.executeAction(veh, 'setFreeze', true)
    end
  end)
end

local function restoreVehicle(veh, forceGhostOff)
  if not veh then return end
  if forceGhostOff ~= false then
    pcall(function() veh:queueLuaCommand('obj:setGhostEnabled(false)') veh:setMeshAlpha(1, "") end)
  end
  pcall(function() veh:queueLuaCommand('electrics.setIgnitionLevel(3)') end)
  pcall(function()
    if core_vehicleBridge and core_vehicleBridge.executeAction then
      core_vehicleBridge.executeAction(veh, 'setFreeze', false)
    end
  end)
end

function M.preSpawnProp(ctx, propName)
  if ctx.getPlayerTeam and ctx.getPlayerTeam() ~= "hider" then return end
  local mode = (ctx.getDisguiseMode and tostring(ctx.getDisguiseMode() or "replace"):lower()) or "replace"
  local effectiveMode = mode
  if mode == "spawnswap" and ctx.isSpawnswapDisabledForRound and ctx.isSpawnswapDisabledForRound() then
    effectiveMode = "replace"
  end
  if mode == "spawnswap" and not spawnswapGuardAllows(ctx) then
    effectiveMode = "replace"
  end
  if mode ~= "spawnswap" and mode ~= "preload" then return end
  if ctx.isSpawnswapDisabledForRound and ctx.isSpawnswapDisabledForRound() then return end
  if not spawnswapGuardAllows(ctx) then return end

  local myVeh = be:getPlayerVehicle(0)
  if not myVeh then return end
  local myVehId = myVeh:getID()
  local myPos = myVeh:getPosition()
  local myRot = myVeh:getRotation()
  local propRot = (quatFromDir(vec3(myVeh:getDirectionVector()):normalized(), vec3(myVeh:getDirectionVectorUp()):normalized())):toTorqueQuat()

  if ctx.getPropVehId and ctx.getPropVehId() and ctx.isHidePhase and ctx.isHidePhase() then
    local prop = be:getObjectByID(ctx.getPropVehId())
    prop:setPosition(myPos)
    prop:setField('rotation', 0, propRot.x .. " " .. propRot.y .. " " .. propRot.z .. " " .. propRot.w) 
    myVeh:queueLuaCommand("obj:setGhostEnabled(true)")
    myVeh:setMeshAlpha(0.125,"")
  end

  if ctx.isHidePhase and not ctx.isHidePhase() then
    myVeh:queueLuaCommand("obj:setGhostEnabled(false)")
    myVeh:setMeshAlpha(1,"")
  end

  if ctx.isPreSpawnAttemptedThisRound and ctx.isPreSpawnAttemptedThisRound() then return end
  if ctx.markPreSpawnAttemptedThisRound then ctx.markPreSpawnAttemptedThisRound() end

  if ctx.getPropVehId and ctx.getPropVehId() then
    local existing = be:getObjectByID(ctx.getPropVehId())
    if existing then return end
  end

  local modelKey = ensureModelAndLabel(propName)
  if not modelKey then return end

  local newId = spawnPropVehicle(modelKey)
  if not newId then return end
  local newVeh = be:getObjectByID(newId)
  if not newVeh then return end

  stashVehicleFarAway(newVeh, myPos, myRot)

  local original = be:getObjectByID(myVehId)
  if original then pcall(function() be:enterVehicle(0, original) end) end

  if ctx.setPropVehId then ctx.setPropVehId(newId) end
  if ctx.setOriginalVehId then ctx.setOriginalVehId(myVehId) end

  reportTempPropServerString(ctx, newId, 8.0, ctx.getCurrentRoundId and ctx.getCurrentRoundId() or nil)

  print("DEBUG: PRESPAWN_OK propId=" .. tostring(newId) .. " originalId=" .. tostring(myVehId))
end

function M.spawnAndAttachProp(ctx, propName)
  if ctx.getPlayerTeam and ctx.getPlayerTeam() ~= "hider" then return end
  if ctx.isAlreadyDisguisedThisRound() then return end
  if ctx.isDisguised() then return end
  if ctx.isDisguiseInProgress() then return end

  ctx.setDisguiseInProgress(true)

  if not core_vehicles or not core_vehicles.replaceVehicle or not core_vehicles.getModelList then
    ctx.beamMessage({ msg = "Prop disguise failed: core_vehicles API not available", ttl = 4, icon = 'error' })
    print("ERROR: core_vehicles API not available")
    ctx.setDisguiseInProgress(false)
    return
  end

  local modelKey, modelLabel, modelErr = ensureModelAndLabel(propName)
  if not modelKey then
    ctx.beamMessage({ msg = "Prop disguise failed: " .. tostring(modelErr), ttl = 4, icon = 'error' })
    ctx.setDisguiseInProgress(false)
    return
  end

  local mode = (ctx.getDisguiseMode and tostring(ctx.getDisguiseMode() or "replace"):lower()) or "replace"
  local effectiveMode = mode
  if mode == "spawnswap" and ctx.isSpawnswapDisabledForRound and ctx.isSpawnswapDisabledForRound() then
    effectiveMode = "replace"
  end
  if mode == "spawnswap" and not spawnswapGuardAllows(ctx) then
    effectiveMode = "replace"
  end
  local forceGhostOff = (ctx.getForceGhostOffOnRestore and ctx.getForceGhostOffOnRestore() ~= false) or true
  local retryCount = math.max(1, math.floor((ctx.getSpawnswapRetryCount and tonumber(ctx.getSpawnswapRetryCount())) or 1))

  local function doReplace(key)
    capturePreDisguise(ctx)
    local cfgKey = pickRandomPropConfig(key)
    if cfgKey then core_vehicles.replaceVehicle(key, { config = cfgKey })
    else core_vehicles.replaceVehicle(key, {}) end
  end

  local function applyPreloadMask(enable)
    local veh = be:getPlayerVehicle(0)
    if not veh then return end
    if enable then
      if forceGhostOff == false then
        pcall(function() veh:queueLuaCommand('obj:setGhostEnabled(true)') end)
      end
      pcall(function() veh:queueLuaCommand('electrics.setIgnitionLevel(0)') end)
    else
      restoreVehicle(veh, forceGhostOff)
    end
  end

  local function doSpawnSwap(key)
    local myVeh = be:getPlayerVehicle(0)
    if not myVeh then return false, "no player vehicle" end

    local oldId = myVeh:getID()
    local oldPos = myVeh:getPosition()
    local oldRot = myVeh:getRotation()
    if ctx.setOriginalVehId then ctx.setOriginalVehId(oldId) end

    local newId = ctx.getPropVehId and ctx.getPropVehId() or nil
    local newVeh = newId and be:getObjectByID(newId) or nil

    if not newVeh then
      local lastErr = "spawn failed"
      for _ = 1, retryCount do
        local spawnedId, spawnErr = spawnPropVehicle(key)
        if spawnedId then
          newId = spawnedId
          newVeh = be:getObjectByID(newId)
          if newVeh then break end
          lastErr = "spawned vehicle object missing"
        else
          lastErr = tostring(spawnErr or lastErr)
        end
      end
      if not newVeh then return false, lastErr end
    end

    if oldPos and oldRot and newVeh.setPositionRotation then
      pcall(function()
        newVeh:setPositionRotation(oldPos.x, oldPos.y, oldPos.z, oldRot.x, oldRot.y, oldRot.z, oldRot.w)
      end)
    end
    restoreVehicle(newVeh, forceGhostOff)
    if forceGhostOff == false then
      pcall(function() newVeh:queueLuaCommand('obj:setGhostEnabled(true)') end)
    end
    pcall(function() be:enterVehicle(0, newVeh) end)

    stashVehicleFarAway(myVeh, oldPos, oldRot)

    if ctx.setPropVehId then ctx.setPropVehId(newId) end
    reportTempPropServerString(ctx, newId, 8.0, ctx.getCurrentRoundId and ctx.getCurrentRoundId() or nil)
    return true
  end

  local ok, err
  if effectiveMode == "preload" then
    applyPreloadMask(true)
    if ctx.getPropVehId and ctx.getPropVehId() then --remove temp prop
      be:getObjectByID(ctx.getPropVehId()):delete()
    end
    ok, err = pcall(function() doReplace(modelKey) end)
    applyPreloadMask(false)
  elseif effectiveMode == "spawnswap" then
    ok, err = doSpawnSwap(modelKey)
  else
    ok, err = pcall(function() doReplace(modelKey) end)
  end

  if not ok then
    if effectiveMode == "spawnswap" then
      if ctx.disableSpawnswapForRound then
        pcall(function() ctx.disableSpawnswapForRound("spawnswap_disguise_failed") end)
      end
      -- Fail closed for spawnswap loop, but immediately fall back to replace so gameplay continues.
      local okReplace, errReplace = pcall(function() doReplace(modelKey) end)
      if okReplace then
        ok = true
        effectiveMode = "replace"
        ctx.beamMessage({ msg = "Spawnswap rejected; using replace fallback", ttl = 3, icon = 'warning' })
      else
        err = errReplace
      end
    end

    if not ok then
      print("WARN: disguise failed for '" .. tostring(modelKey) .. "' => " .. tostring(err) .. "; fallback replace(random)")
    local k, name = pickRandomPropModelKey()
    if not k then
      ctx.beamMessage({ msg = "Prop disguise failed: " .. tostring(modelKey), ttl = 4, icon = 'error' })
      ctx.setDisguiseInProgress(false)
      return
    end
    modelKey = k
    modelLabel = name or k
    ok, err = pcall(function() doReplace(modelKey) end)
    end
  end

  if ok then
    ctx.setDisguised(true)
    ctx.setPropStateRequestedRound(nil)
    ctx.beamMessage({ msg = "Disguised as prop: " .. tostring(modelLabel), ttl = 4, icon = 'local_shipping' })
    print("DEBUG: Disguise success: " .. tostring(modelKey) .. " (mode=" .. tostring(effectiveMode) .. ")")
  else
    ctx.beamMessage({ msg = "Prop disguise failed: " .. tostring(modelKey), ttl = 4, icon = 'error' })
    print("ERROR: Failed to disguise as '" .. tostring(modelKey) .. "': " .. tostring(err))
  end

  ctx.setDisguiseInProgress(false)
end

return M
