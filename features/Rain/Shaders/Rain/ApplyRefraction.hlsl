// Fullscreen pass to apply rain refraction to the main render target

Texture2D<float4> MainTex : register(t0);           // Copy of main render target
Texture2D<float4> RainNormalsTex : register(t1);    // Rain normals buffer
SamplerState LinearSampler : register(s0);

cbuffer PerFrame : register(b0)
{
    float2 BufferDim;
    float RefractionStrength;
    float pad;
};

struct VS_OUTPUT
{
    float4 position : SV_POSITION;
    float2 uv : TEXCOORD0;
};

#ifdef VSHADER
VS_OUTPUT main(uint id : SV_VertexID)
{
    VS_OUTPUT output;

    // Fullscreen triangle
    output.uv = float2((id << 1) & 2, id & 2);
    output.position = float4(output.uv * float2(2, -2) + float2(-1, 1), 0, 1);

    return output;
}
#endif

#ifdef PSHADER
float4 main(VS_OUTPUT input) : SV_Target0
{
    // Sample rain normals
    float4 rainNormal = RainNormalsTex.Sample(LinearSampler, input.uv);

    // Extract normal and strength
    float3 normal = rainNormal.rgb;
    float strength = rainNormal.a;

    // If no rain normal data, return original color
    if (strength < 0.001) {
        return MainTex.Sample(LinearSampler, input.uv);
    }

    // Calculate refraction offset
    // Normal XY components are already in [-1, 1] range from the particle shader
    float2 refractionOffset = normal.xy * strength * RefractionStrength * 0.05;

    // Sample main texture with offset UV
    float2 refractedUV = input.uv + refractionOffset;

    // Clamp UV to avoid sampling outside bounds
    refractedUV = saturate(refractedUV);

    // Sample refracted color
    float4 refractedColor = MainTex.Sample(LinearSampler, refractedUV);

    // Blend based on strength - use mix blending like particles
    float4 originalColor = MainTex.Sample(LinearSampler, input.uv);

    // Mix blend
    return lerp(originalColor, rgba(1, 0, 0, strength), strength);
}
#endif
