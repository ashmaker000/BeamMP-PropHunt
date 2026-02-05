local prophuntBlurPostFXCallbacks = {}

prophuntBlurPostFXCallbacks.onAdd = function()
  local fx = scenetree.findObject("PropHuntBlurPostFX")
  if fx then
    fx.blurStrength = 1.0
  end
end

prophuntBlurPostFXCallbacks.setShaderConsts = function()
  local fx = scenetree.findObject("PropHuntBlurPostFX")
  if fx then
    -- Some shaders may ignore this; keep it as a best-effort knob.
    fx:setShaderConst("$blurStrength", tostring(fx.blurStrength or 1.0))
  end
end

rawset(_G, "PropHuntBlurPostFXCallbacks", prophuntBlurPostFXCallbacks)

-- Best-effort: BeamNG ships common postFX blur shaders. If paths differ, vignette will still work.
local blurShader = scenetree.findObject("PropHuntBlurShader")
if not blurShader then
  blurShader = createObject("ShaderData")
  blurShader.DXVertexShaderFile = "shaders/common/postFx/gaussianBlur/gaussianBlurP.hlsl"
  blurShader.DXPixelShaderFile  = "shaders/common/postFx/gaussianBlur/gaussianBlurP.hlsl"
  blurShader.pixVersion = 5.0
  blurShader:registerObject("PropHuntBlurShader")
end

local blurPostFX = scenetree.findObject("PropHuntBlurPostFX")
if not blurPostFX then
  blurPostFX = createObject("PostEffect")
  blurPostFX.isEnabled = false
  blurPostFX.allowReflectPass = false
  blurPostFX:setField("renderTime", 0, "PFXBeforeBin")
  blurPostFX:setField("renderBin", 0, "AfterPostFX")

  blurPostFX:setField("shader", 0, "PropHuntBlurShader")
  blurPostFX:setField("stateBlock", 0, "PFX_DefaultStateBlock")
  blurPostFX:setField("texture", 0, "$backBuffer")

  blurPostFX:registerObject("PropHuntBlurPostFX")
end
