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
  pcall(function() veh:queueLuaCommand('obj:setGhostEnabled(true)') end)
  pcall(function() veh:setMeshAlpha(0, "", false) end)
  pcall(function() veh:queueLuaCommand('electrics.setIgnitionLevel(0)') end)
  pcall(function()
    if core_vehicleBridge and core_vehicleBridge.executeAction then
      core_vehicleBridge.executeAction(veh, 'setFreeze', true)
    end
  end)
end

local function restoreVehicle(veh)
  if not veh then return end
  pcall(function() veh:queueLuaCommand('obj:setGhostEnabled(false)') end)
  pcall(function() veh:setMeshAlpha(10000, "", false) end)
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
  if mode ~= "spawnswap" then return end

  if ctx.getPropVehId and ctx.getPropVehId() then
    local existing = be:getObjectByID(ctx.getPropVehId())
    if existing then return end
  end

  local myVeh = be:getPlayerVehicle(0)
  if not myVeh then return end
  local myVehId = myVeh:getID()
  local myPos = myVeh:getPosition()
  local myRot = myVeh:getRotation()

  local modelKey = ensureModelAndLabel(propName)
  if not modelKey then return end

  local newId = spawnPropVehicle(modelKey)
  if not newId then return end
  local newVeh = be:getObjectByID(newId)
  if not newVeh then return end

  stashVehicleFarAway(newVeh, myPos, myRot)

  -- Some builds auto-switch player control/camera to newly spawned vehicle.
  -- Force the player back to their original car during hide phase.
  local original = be:getObjectByID(myVehId)
  if original then
    pcall(function() be:enterVehicle(0, original) end)
  end

  if ctx.setPropVehId then ctx.setPropVehId(newId) end
  if ctx.setOriginalVehId then ctx.setOriginalVehId(myVehId) end

  local function reportTempProp()
    if not TriggerServerEvent then return end
    if not MPVehicleGE then return end

    local serverVeh = nil

    -- Prefer direct lookup from MPVehicleGE cache to avoid noisy getServerVehicleID errors
    if MPVehicleGE.getVehicles then
      for _, veh in pairs(MPVehicleGE.getVehicles() or {}) do
        if tonumber(veh.gameVehicleID) == tonumber(newId) then
          serverVeh = tostring(veh.serverVehicleString or "")
          break
        end
      end
    end

    -- Fallback if cache has not populated yet
    if (not serverVeh or serverVeh == "") and MPVehicleGE.getServerVehicleID then
      local ok, sv = pcall(function() return MPVehicleGE.getServerVehicleID(newId) end)
      if ok and sv then serverVeh = tostring(sv) end
    end

    if serverVeh and serverVeh ~= "" then
      TriggerServerEvent("PropHunt_tempPropSet", serverVeh)
    end
  end

  reportTempProp()
  if scheduler and scheduler.add then
    local waited = 0
    scheduler.add(function(dt)
      waited = waited + (dt or 0)
      reportTempProp()
      return waited < 2.0
    end)
  end

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

  local function doReplace(key)
    local cfgKey = pickRandomPropConfig(key)
    if cfgKey then core_vehicles.replaceVehicle(key, { config = cfgKey })
    else core_vehicles.replaceVehicle(key, {}) end
  end

  local function applyPreloadMask(enable)
    local veh = be:getPlayerVehicle(0)
    if not veh then return end
    if enable then
      pcall(function() veh:queueLuaCommand('obj:setGhostEnabled(true)') end)
      pcall(function() veh:setMeshAlpha(0, "", false) end)
      pcall(function() veh:queueLuaCommand('electrics.setIgnitionLevel(0)') end)
    else
      restoreVehicle(veh)
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

    if newVeh then
      print("DEBUG: SWAP_USING_PRESPAWN propId=" .. tostring(newId))
    end

    if not newVeh then
      print("DEBUG: SWAP_NO_PRESPAWN - spawning at swap time")
      local spawnedId, spawnErr = spawnPropVehicle(key)
      if not spawnedId then return false, spawnErr end
      newId = spawnedId
      newVeh = be:getObjectByID(newId)
      if not newVeh then return false, "spawned vehicle object missing" end
    end

    if oldPos and oldRot and newVeh.setPositionRotation then
      pcall(function()
        newVeh:setPositionRotation(oldPos.x, oldPos.y, oldPos.z, oldRot.x, oldRot.y, oldRot.z, oldRot.w)
      end)
    end
    restoreVehicle(newVeh)
    pcall(function() be:enterVehicle(0, newVeh) end)

    stashVehicleFarAway(myVeh, oldPos, oldRot)

    if ctx.setPropVehId then ctx.setPropVehId(newId) end
    return true
  end

  local ok, err
  if mode == "preload" then
    applyPreloadMask(true)
    ok, err = pcall(function() doReplace(modelKey) end)
    applyPreloadMask(false)
  elseif mode == "spawnswap" then
    ok, err = doSpawnSwap(modelKey)
  else
    ok, err = pcall(function() doReplace(modelKey) end)
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

  if ok then
    ctx.setDisguised(true)
    ctx.setPropStateRequestedRound(nil)
    ctx.beamMessage({ msg = "Disguised as prop: " .. tostring(modelLabel), ttl = 4, icon = 'local_shipping' })
    print("DEBUG: Disguise success: " .. tostring(modelKey) .. " (mode=" .. tostring(mode) .. ")")
  else
    ctx.beamMessage({ msg = "Prop disguise failed: " .. tostring(modelKey), ttl = 4, icon = 'error' })
    print("ERROR: Failed to disguise as '" .. tostring(modelKey) .. "': " .. tostring(err))
  end

  ctx.setDisguiseInProgress(false)
end

return M
