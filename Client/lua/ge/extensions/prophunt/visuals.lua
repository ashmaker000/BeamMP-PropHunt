local M = {}
M.BUILD = "2026-02-11-phase2e"

local seekerVisualBlockActive = false

function M.setSeekerVisualBlock(state)
  seekerVisualBlockActive = (state == true)

  if extensions and extensions.vignetteShaderAPI then
    if seekerVisualBlockActive then
      extensions.vignetteShaderAPI.setEnabled(true)
      -- Full-screen blackout (same trick as flashbang, but black).
      extensions.vignetteShaderAPI.setInnerRadius(0.0)
      extensions.vignetteShaderAPI.setOuterRadius(0.0)
      extensions.vignetteShaderAPI.setColor(Point4F(0, 0, 0, 1.0))
    else
      extensions.vignetteShaderAPI.resetVignette()
    end
  end

  if extensions and extensions.prophuntBlurAPI then
    if state then
      extensions.prophuntBlurAPI.setStrength(3.0)
      extensions.prophuntBlurAPI.setEnabled(true)
    else
      extensions.prophuntBlurAPI.reset()
    end
  end
end

function M.setProximityVignette(strength, intensity)
  if not extensions or not extensions.vignetteShaderAPI then return end

  -- Never let proximity effects override the seeker blackout during hide phase.
  if seekerVisualBlockActive then return end

  local alpha = 0
  if strength and strength > 0 and intensity and intensity > 0 then
    local normalizedStrength = math.min(math.max(strength, 0), 1)
    alpha = math.min(normalizedStrength * math.max(intensity, 0) * 1.4, 0.85)
  end

  if alpha > 0 then
    extensions.vignetteShaderAPI.setEnabled(true)
    extensions.vignetteShaderAPI.setInnerRadius(0.6)
    extensions.vignetteShaderAPI.setOuterRadius(1.2)
    extensions.vignetteShaderAPI.setColor(Point4F(1, 0, 0, alpha))
  else
    extensions.vignetteShaderAPI.resetVignette()
  end
end

function M.strengthFromDistance(d, maxDist)
  if not d then return 0 end
  local range = math.max((maxDist or 120), 1)
  local s = 1.0 - math.min(1.0, d / range)
  if s < 0 then s = 0 end
  if s > 1 then s = 1 end
  return s
end

return M
