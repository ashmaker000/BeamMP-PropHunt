local M = {}
M.BUILD = "2026-02-11-phase2e"

function M.new(opts)
  opts = opts or {}
  local self = {
    tauntDir = opts.tauntDir or "art/Sounds/Taunts/all",
    tauntDistance = tonumber(opts.tauntDistance) or 50,
    volume = tonumber(opts.volume) or 1,
    maxLength = tonumber(opts.maxLength) or 10,
    availableTauntFiles = {},
    activeEmitters = {},
    soundEmitterReady = false,
  }

  function self.initTauntFiles()
    self.availableTauntFiles = {}
    if not (FS and FS.findFiles) then return end
    local files = FS:findFiles(self.tauntDir, "*.ogg", -1, false, false)
    for _, path in ipairs(files or {}) do
      if string.sub(path, 1, #self.tauntDir) == self.tauntDir then
        self.availableTauntFiles[#self.availableTauntFiles + 1] = path
      end
    end
  end

  function self.getTauntCount()
    return #self.availableTauntFiles
  end

  function self.getRandomTauntSound()
    if #self.availableTauntFiles == 0 then
      return string.format("%s/taunt%02d.ogg", self.tauntDir, math.random(1, 24))
    end
    return self.availableTauntFiles[math.random(#self.availableTauntFiles)]
  end

  function self.setEmitterReady(v)
    self.soundEmitterReady = v and true or false
  end

  local function trySoundEmitterExtension(filename, vehID)
    if not self.soundEmitterReady then return false end
    if not (extensions and extensions.soundEmitterControl and extensions.soundEmitterControl.createSoundEmitter) then
      return false
    end
    if filename and FS and FS.fileExists and not FS:fileExists(filename) then
      return false
    end
    extensions.soundEmitterControl.createSoundEmitter(filename, "PropHunt_SFX_" .. tostring(vehID), vehID)
    return true
  end

  function self.playSound(filename, vehID, maxDistance, volumeOverride)
    if not filename or not vehID then return end
    if not maxDistance and not volumeOverride and trySoundEmitterExtension(filename, vehID) then
      return
    end

    if filename and FS and FS.fileExists and not FS:fileExists(filename) then
      print("PropHunt WARN: sound file missing: " .. tostring(filename))
    end

    if self.activeEmitters[vehID] then
      local oldEmitter = scenetree.findObjectById(self.activeEmitters[vehID].id)
      if oldEmitter then oldEmitter:delete() end
      self.activeEmitters[vehID] = nil
    end

    local veh = be:getObjectByID(vehID)
    local pos
    if not veh then
      local playerVeh = be:getPlayerVehicle(0)
      if not playerVeh then return end
      pos = playerVeh:getPosition()
    else
      pos = veh:getPosition()
    end

    local soundDistance = maxDistance or self.tauntDistance

    local newObj = createObject('SFXEmitter')
    newObj:setPosition(pos)
    newObj:setField('filename', 0, filename)
    newObj:setField('playOnAdd', 0, "1")
    newObj:setField('isLooping', 0, "0")
    newObj:setField('maxDistance', 0, tostring(soundDistance))
    local vol = volumeOverride or self.volume
    newObj:setField('volume', 0, tostring(vol))
    newObj.canSave = false
    newObj:registerObject("PropHunt_SFX_" .. vehID)

    local grp = scenetree.MissionGroup
    if grp then grp:addObject(newObj) end
    self.activeEmitters[vehID] = { id = newObj:getID(), timer = self.maxLength }
  end

  function self.updateEmitters(dt)
    for vid, data in pairs(self.activeEmitters) do
      local emitter = scenetree.findObjectById(data.id)
      if emitter then
        data.timer = data.timer - dt
        if data.timer <= 0 then
          emitter:delete()
          self.activeEmitters[vid] = nil
        else
          local veh = be:getObjectByID(vid)
          if veh then emitter:setPosition(veh:getPosition()) end
        end
      else
        self.activeEmitters[vid] = nil
      end
    end
  end

  return self
end

return M
