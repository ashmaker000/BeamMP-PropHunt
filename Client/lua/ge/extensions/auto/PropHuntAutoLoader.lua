local M = {}

local loaded = false

local function ensureLoaded()
  if loaded and extensions and extensions.PropHunt and type(extensions.PropHunt.manualTaunt) == "function" then
    return
  end

  if extensions and extensions.load then
    pcall(function() extensions.load("PropHunt") end)
    pcall(function() extensions.load("PropHuntKeybinds") end)
  end

  local ph = extensions and extensions.PropHunt or nil
  if not (ph and type(ph.requestStateBurst) == "function") then
    local ok, mod = pcall(require, "ge.extensions.prophunt.core")
    if not ok or not mod then
      ok, mod = pcall(require, "ge/extensions/prophunt/core")
    end
    if ok and mod then
      ph = mod
      if extensions then extensions.PropHunt = mod end
      if type(mod.onExtensionLoaded) == "function" then
        pcall(function() mod.onExtensionLoaded() end)
      end
      print("DEBUG: PropHuntAutoLoader directly loaded PropHunt core fallback")
    else
      print("ERROR: PropHuntAutoLoader direct core load failed: " .. tostring(mod))
    end
  end

  if ph and type(ph.requestStateBurst) == "function" then
    pcall(function() ph.requestStateBurst() end)
    loaded = true
  end
end

M.onExtensionLoaded = function()
  print("DEBUG: PropHuntAutoLoader loaded")
  ensureLoaded()
end

M.onUpdate = function(dt)
  ensureLoaded()
end

return M
