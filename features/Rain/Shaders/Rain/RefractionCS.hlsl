// Rain Refraction Compute Shader
// Applies refraction to the scene based on rain normals

#include "Common/SharedData.hlsli"

RWTexture2D<float4> MainRW : register(u0);

Texture2D<float4> MainCopy : register(t0);
Texture2D<float4> RainNormals : register(t1);   // RG = normal, B = depth, A = mask
Texture2D<float4> RainLight : register(t2);     // RGB = light color from particles, A = mask

cbuffer RefractionCB : register(b1)
{
	float RefractionStrength;
	float LightOpacity;
	float IOR;
	float pad;
};

[numthreads(8, 8, 1)]
void main(uint3 DTid : SV_DispatchThreadID)
{
	// Early exit if outside screen bounds
	if (any(DTid.xy >= uint2(SharedData::BufferDim.xy)))
		return;

	// Sample rain normals buffer: RG = normal, B = depth, A = mask
	float4 rainData = RainNormals[DTid.xy];
	float2 normalEncoded = rainData.rg;
	float mask = rainData.a;

	// If no rain normal data, just copy original
	if (mask < 0.001) {
		MainRW[DTid.xy] = MainCopy[DTid.xy];
		return;
	}

	// Normal is [0,1] where 0.5 = no offset, convert to [-1,1]
	float2 normalXY = (normalEncoded - 0.5) * 2.0;

	// Reconstruct full 3D normal (sphere normal pointing toward camera)
	float normalLenSq = dot(normalXY, normalXY);
	float normalZ = sqrt(saturate(1.0 - normalLenSq));
	float3 N = normalize(float3(normalXY.x, normalXY.y, normalZ));

	// View direction (camera looking into screen)
	float3 V = float3(0, 0, 1);

	// Apply Snell's Law: refract the view direction through the sphere surface
	float eta = 1.0 / IOR;
	float3 refractedDir = refract(-V, N, eta);

	// Use refracted direction directly as offset (samples opposite side for inversion)
	float2 refractionOffset = refractedDir.xy;

	// Scale by strength and mask
	float2 offset = refractionOffset * mask * RefractionStrength * 500.0;
	float2 refractedCoordF = float2(DTid.xy) + offset;

	// Clamp to screen bounds
	float2 screenMax = SharedData::BufferDim.xy - 1.0;
	refractedCoordF = clamp(refractedCoordF, float2(0.0, 0.0), screenMax);

	float4 result = MainCopy[int2(refractedCoordF)];

	// Add light contribution
	float3 lightColor = RainLight[DTid.xy].rgb;
	result.rgb += lightColor * LightOpacity;

	MainRW[DTid.xy] = result;
}
