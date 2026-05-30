local M = {}

local enabled = false
local strength = 1.0

local function ensureVignette()
  if extensions and not extensions.prophuntVignetteAPI and extensions.load then
    pcall(function() extensions.load("prophuntVignetteAPI") end)
  end
  return extensions and extensions.prophuntVignetteAPI or nil
end

local function setEnabled(state)
  enabled = state and true or false
  local vignette = ensureVignette()
  if not vignette then return end

  if enabled then
    local alpha = math.max(0.45, math.min(0.95, (tonumber(strength) or 1.0) / 3.2))
    vignette.setEnabled(true)
    vignette.setColor(Point4F(0.015, 0.018, 0.025, alpha))
    vignette.setInnerRadius(0)
    vignette.setOuterRadius(0)
  else
    vignette.resetVignette()
  end
end

local function setStrength(v)
  strength = tonumber(v) or 1.0
  if enabled then
    setEnabled(true)
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
