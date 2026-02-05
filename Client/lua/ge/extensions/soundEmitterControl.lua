local M = {}

local soundDistance = 250
local volume = 1
local maxSoundEffectLength = 10 -- seconds before emitter cleanup

local vehMap = {}
local vehMapTimer = {}

local function setSoundDistance(distance)
  if type(distance) == "number" then soundDistance = distance end
end

local function setSoundVolume(soundVolume)
  if type(soundVolume) == "number" then volume = soundVolume end
end

local function setMaxSoundEffectLength(length)
  if type(length) == "number" then maxSoundEffectLength = length end
end

local function createSoundEmitter(soundPath, name, vehID)
  if vehMap[vehID] then
    local emitter = scenetree.findObjectById(vehMap[vehID])
    if emitter then emitter:delete() end
  end

  if not FS:fileExists(soundPath) then return end

  local x, y, z = be:getObjectOOBBCenterXYZ(vehID)
  local newObj = createObject('SFXEmitter')
  newObj:setPosition(vec3(x, y, z))
  newObj:setField('filename', 0, soundPath)
  newObj:setField('playOnAdd', 0, "1")
  newObj:setField('isLooping', 0, "0")
  newObj:setField('maxDistance', 0, tostring(soundDistance))
  newObj:setField('volume', 0, tostring(volume))
  newObj.canSave = false
  newObj:registerObject(name)

  vehMap[vehID] = newObj:getID()
  vehMapTimer[vehID] = maxSoundEffectLength

  local grp = scenetree.MissionGroup
  if grp then
    grp:addObject(newObj)
  else
    newObj:delete()
    vehMap[vehID] = nil
  end
end

local function deleteEmitter(vehID)
  if vehMap[vehID] then
    local emitter = scenetree.findObjectById(vehMap[vehID])
    if emitter then emitter:delete() end
    vehMap[vehID] = nil
  end
end

local function teleportEmitters(dt)
  for vehID, emitterID in pairs(vehMap) do
    local emitter = scenetree.findObjectById(emitterID)
    if emitter then
      local x, y, z = be:getObjectOOBBCenterXYZ(vehID)
      emitter:setPosRot(x, y, z, 0, 0, 0, 0)

      local timer = (vehMapTimer[vehID] or maxSoundEffectLength) - dt
      if timer < 0 then
        deleteEmitter(vehID)
      else
        vehMapTimer[vehID] = timer
      end
    end
  end
end

local function onVehicleDestroyed(vehID)
  deleteEmitter(vehID)
end

local function onExtensionUnloaded()
  for vehID, _ in pairs(vehMap) do
    deleteEmitter(vehID)
  end
end

local function onPreRender(dt)
  teleportEmitters(dt)
end

local function playRandomTaunt(encodedSoundName, vehID)
  if not encodedSoundName then return end
  createSoundEmitter("art/Sounds/Taunts/" .. encodedSoundName, "Taunt_" .. vehID, vehID)
end

M.onPreRender = onPreRender
M.createSoundEmitter = createSoundEmitter
M.playRandomTaunt = playRandomTaunt
M.onVehicleDestroyed = onVehicleDestroyed
M.setSoundDistance = setSoundDistance
M.setSoundVolume = setSoundVolume
M.setMaxSoundEffectLength = setMaxSoundEffectLength

-- BeamMP server controls (safe no-ops if not present)
if MPGameNetwork then AddEventHandler("tauntmod_setSoundDistance", setSoundDistance) end
if MPGameNetwork then AddEventHandler("tauntmod_setSoundVolume", setSoundVolume) end
if MPGameNetwork then AddEventHandler("tauntmod_setMaxSoundEffectLength", setMaxSoundEffectLength) end

M.onInit = function() setExtensionUnloadMode(M, "manual") end
M.onExtensionUnloaded = onExtensionUnloaded

return M
