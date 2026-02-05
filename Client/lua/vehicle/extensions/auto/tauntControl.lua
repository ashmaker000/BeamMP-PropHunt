local M = {}

-- Random taunts for any vehicle.
-- NOTE: expects .ogg files under art/Sounds/Taunts/<folder>/*.ogg

math.randomseed(os.clock() + obj:getID())

local soundPaths = FS:findFiles("art/Sounds/Taunts/", "*.ogg", -1, false, false)
local filenames = {}
local folderLookup = {}
local folderCount = 0

for _, pathName in pairs(soundPaths) do
  local shortName = string.sub(pathName, 20, string.len(pathName)) -- strip "art/Sounds/Taunts/"
  local folderName, fileName = shortName:match("(.+)/(.+)")
  if folderName and fileName then
    if not filenames[folderName] then
      filenames[folderName] = {}
      folderCount = folderCount + 1
      folderLookup[#folderLookup + 1] = folderName
    end
    filenames[folderName][#filenames[folderName] + 1] = fileName
  end
end

local tauntCoolDown = 2
local tauntTimer = 0
local showUIMessage = false
local lastRandomSoundIndex = ""

local function randomTaunt()
  if folderCount == 0 then
    guihooks.message({ txt = "No taunt sounds found (art/Sounds/Taunts/)" }, 3, "tauntMissing", "warning")
    return
  end

  if tauntTimer == 0 then
    tauntTimer = tauntCoolDown

    local randomFolderIndex = math.random(1, folderCount)
    local folderName = folderLookup[randomFolderIndex]
    local randomSoundIndex = math.random(1, #filenames[folderName])
    local fileName = filenames[folderName][randomSoundIndex]

    -- replicate via BeamMP electrics sync (string key)
    electrics.values.randomSoundIndex = tostring(folderName) .. "/" .. tostring(fileName)
  else
    showUIMessage = true
  end
end

local function playTaunt(index)
  if index ~= "" then
    obj:queueGameEngineLua("if soundEmitterControl then soundEmitterControl.playRandomTaunt(" .. jsonEncode(index) .. ", " .. obj:getID() .. ") end")
  end
end

local function updateGFX(dt)
  if tauntTimer ~= 0 then
    tauntTimer = math.max(0, tauntTimer - dt)

    if showUIMessage then
      local time = math.floor(tauntTimer * 10) / 10
      local text = "Taunt Cooldown " .. tostring(time)
      if time == 1 then text = text .. ".0" end
      guihooks.message({ txt = text }, 0.1, "tauntTimer", "warning")
    end

    if tauntTimer < tauntCoolDown / 2 then
      -- allow same sound twice; BeamMP needs time to sync
      electrics.values.randomSoundIndex = ""
    end

    if tauntTimer == 0 then
      showUIMessage = false
    end
  end

  if lastRandomSoundIndex ~= (electrics.values.randomSoundIndex or "") then
    playTaunt(electrics.values.randomSoundIndex)
  end

  lastRandomSoundIndex = electrics.values.randomSoundIndex or ""
end

M.randomTaunt = randomTaunt
M.updateGFX = updateGFX

return M
