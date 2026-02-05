require("client/postFx/prophuntBlur")

local M = {}

local fx = scenetree.findObject("PropHuntBlurPostFX")
local enabled = false

local function setEnabled(state)
  enabled = state and true or false
  if fx then
    fx.isEnabled = enabled
  end
end

local function setStrength(v)
  if fx then
    fx.blurStrength = v or 1.0
  end
end

local function reset()
  setStrength(1.0)
  setEnabled(false)
end

local function isEnabled()
  return enabled
end

M.setEnabled = setEnabled
M.setStrength = setStrength
M.reset = reset
M.isEnabled = isEnabled
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
