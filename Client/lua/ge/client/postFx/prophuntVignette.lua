local prophuntVignettePostFXCallbacks = {}

prophuntVignettePostFXCallbacks.onAdd = function()
    local postFX = scenetree.findObject("ProphuntVignettePostFX")
    if postFX then
        postFX.innerRadius = 0
        postFX.outerRadius = 1
        postFX.center = Point2F(0.5, 0.5)
        postFX.color = Point4F(0, 0, 0, 0.5)
    end
end

prophuntVignettePostFXCallbacks.setShaderConsts = function()
    local postFX = scenetree.findObject("ProphuntVignettePostFX")
    if postFX then
        postFX:setShaderConst("$innerRadius", postFX.innerRadius)
        postFX:setShaderConst("$outerRadius", postFX.outerRadius)
        local center = postFX.center
        postFX:setShaderConst("$center", center.x and string.format("%g %g", center.x, center.y) or center)
        local color = postFX.color
        postFX:setShaderConst("$color", color.x and string.format("%g %g %g %g", color.x, color.y, color.z, color.w) or color)
    end
end

rawset(_G, "ProphuntVignettePostFXCallbacks", prophuntVignettePostFXCallbacks)

local shader = scenetree.findObject("ProphuntVignetteShader")
if not shader then
    shader = createObject("ShaderData")
    shader.DXVertexShaderFile = "shaders/common/postFx/prophuntVignette/prophuntVignetteP.hlsl"
    shader.DXPixelShaderFile = "shaders/common/postFx/prophuntVignette/prophuntVignetteP.hlsl"
    shader.pixVersion = 5.0
    shader:registerObject("ProphuntVignetteShader")
end

local postFX = scenetree.findObject("ProphuntVignettePostFX")
if not postFX then
    postFX = createObject("PostEffect")
    postFX.isEnabled = false
    postFX.allowReflectPass = false
    postFX:setField("renderTime", 0, "PFXBeforeBin")
    postFX:setField("renderBin", 0, "AfterPostFX")
    postFX:setField("shader", 0, "ProphuntVignetteShader")
    postFX:setField("stateBlock", 0, "PFX_DefaultStateBlock")
    postFX:setField("texture", 0, "$backBuffer")
    postFX:registerObject("ProphuntVignettePostFX")
end
