require("client/postFx/prophuntVignette")

local M = {}

local function findVignettePostFX()
    local fx = scenetree.findObject("ProphuntVignettePostFX")
    if not fx then
        fx = scenetree.findObject("prophuntVignette PostFX")
    end
    return fx
end

local vignettePostFX = findVignettePostFX()

local enabled = false

local function setEnabled(state)
	enabled = state
	if not vignettePostFX then return end
	vignettePostFX.isEnabled = state
	vignettePostFX.color = Point4F(0, 0.15, 0,1)
end

local function setDistance(distancecolor)
	if not vignettePostFX then return end
	vignettePostFX.innerRadius = 1 - math.min(0,distancecolor)
	vignettePostFX.outerRadius = 2.1 - math.min(0,distancecolor)
end

local function resetVignette()
	if not vignettePostFX then setEnabled(false); return end
	vignettePostFX.innerRadius = 0
	vignettePostFX.outerRadius = 0
	vignettePostFX.center = Point2F(0.5, 0.5)
	vignettePostFX.color = Point4F(0, 0.2, 0, 0)
	setEnabled(false)
end

local function setInnerRadius(value)
	if not vignettePostFX then return end
	vignettePostFX.innerRadius = value or 1
end
local function setOuterRadius(value)
	if not vignettePostFX then return end
	vignettePostFX.outerRadius = value or 1
end
local function setColor(color)
	if not vignettePostFX then return end
	vignettePostFX.color = color --Point4F(0, 0.2, 0, 0)
end

local function isEnabled()
	return enabled
end

M.setEnabled = setEnabled
M.isEnabled = isEnabled
M.setDistance = setDistance
M.resetVignette = resetVignette

M.setInnerRadius = setInnerRadius
M.setOuterRadius = setOuterRadius
M.setColor = setColor


M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M