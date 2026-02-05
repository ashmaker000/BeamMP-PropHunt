#ifndef _PROPHUNT_VIGNETTE_H_HLSL_
#define _PROPHUNT_VIGNETTE_H_HLSL_

#include "../postFx.h.hlsl"

cbuffer perDraw
{
    float innerRadius;
    float outerRadius;
    float2 center;
    float4 color;

    POSTFX_UNIFORMS
};

uniform_sampler2D( backBuffer, 0 );

#include "../postFx.hlsl"

#endif //_prophuntVignette _H_HLSL_
