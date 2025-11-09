// Far Rain Compute Shader
// Rain on two spheres around the player (one tilted 3 degrees), scrolling down in world space

#include "Common/FrameBuffer.hlsli"
#include "Common/SharedData.hlsli"
#include "Common/VR.hlsli"

RWTexture2D<float4> MainRW : register(u0);

Texture2D<float> DepthTexture : register(t0);
Texture2DArray<float3> BlueNoiseTexture : register(t1);  // 128x128x64 blue noise

SamplerState LinearSampler : register(s0);

cbuffer FarRainCB : register(b1)
{
	float FarRainDistance;      // Distance where effect starts fading in
	float FarRainMaxDistance;   // Distance where effect is at full strength
	float FarRainOpacity;       // Overall opacity
	float FarRainSpeed;         // Scroll speed

	float FarRainStretch;       // Y-axis stretch for rain streaks
	float FarRainScale;         // Noise tiling scale
	float FarRainHorizonAngle;  // Angle from horizon in radians (~0.785 = 45deg)
	float Time;                 // Animation time

	float2 BufferDim;           // Screen dimensions
	float WindAngleRelative;    // Wind direction relative to player view (radians)
	float WindTilt;             // Tilt angle based on wind strength (radians)

	float3 DirLightColor;       // Directional light color
	float DirLightAngle;        // Directional light angle relative to view
};

// Sample noise with Y-only linear filtering (point in X to keep sharp vertical streaks)
// Uses 3-tap vertical filter for smoother result
float SampleNoiseYLinear(float2 uv, float slice)
{
	float2 texSize = 128.0;
	float2 texel = uv * texSize;

	// Point sample in X
	int x = int(floor(texel.x)) & 127;  // wrap
	int sliceIdx = int(slice * 64) & 63;

	// 3-tap vertical filter for smoother result
	float yf = frac(texel.y);
	int y0 = int(floor(texel.y)) & 127;
	int y1 = (y0 + 1) & 127;
	int y2 = (y0 + 2) & 127;

	float s0 = BlueNoiseTexture.Load(int4(x, y0, sliceIdx, 0)).r;
	float s1 = BlueNoiseTexture.Load(int4(x, y1, sliceIdx, 0)).r;
	float s2 = BlueNoiseTexture.Load(int4(x, y2, sliceIdx, 0)).r;

	// Smooth interpolation
	float t = yf;
	return lerp(lerp(s0, s1, t), lerp(s1, s2, t), t * 0.5);
}

// Rotate direction around Z axis (horizontal wind direction)
float3 RotateZ(float3 dir, float angle)
{
	float c = cos(angle);
	float s = sin(angle);
	return float3(dir.x * c - dir.y * s, dir.x * s + dir.y * c, dir.z);
}

// Rotate direction around X axis (tilt for wind angle)
float3 RotateX(float3 dir, float angle)
{
	float c = cos(angle);
	float s = sin(angle);
	return float3(dir.x, dir.y * c - dir.z * s, dir.y * s + dir.z * c);
}

// Apply wind tilt: rotate into wind space, tilt, rotate back
float3 ApplyWindTilt(float3 dir, float windAngle, float tiltAngle)
{
	// Rotate to align with wind direction
	float3 rotated = RotateZ(dir, -windAngle);
	// Tilt in the wind direction
	rotated = RotateX(rotated, tiltAngle);
	// Rotate back
	return RotateZ(rotated, windAngle);
}

[numthreads(8, 8, 1)]
void main(uint3 dispatchID : SV_DispatchThreadID)
{
	// Early exit if outside screen bounds (use SharedData like DeferredCompositeCS)
	if (any(dispatchID.xy >= uint2(SharedData::BufferDim.xy)))
		return;

	// UV calculation exactly like DeferredCompositeCS
	float2 uv = float2(dispatchID.xy + 0.5) * SharedData::BufferDim.zw;
	uv *= FrameBuffer::DynamicResolutionParams2.xy;

	uint eyeIndex = Stereo::GetEyeIndexFromTexCoord(uv);
	uv = Stereo::ConvertFromStereoUV(uv, eyeIndex);

	// Sample scene depth
	float depth = DepthTexture[dispatchID.xy];

	// Convert to linear depth
	float linearDepth = SharedData::GetScreenDepth(depth);

	// Distance-based opacity (farther = more visible)
	float distanceFade = saturate((linearDepth - FarRainDistance) / (FarRainMaxDistance - FarRainDistance));

	if (distanceFade <= 0.0)
		return;

	// View direction at infinity (use far plane depth=1, not scene depth)
	// Rain is on a sphere at infinity - doesn't wrap around geometry
	float4 clipPos = float4(2 * float2(uv.x, -uv.y + 1) - 1, 1.0, 1);
	float4 worldPos = mul(FrameBuffer::CameraViewProjInverse[eyeIndex], clipPos);
	float3 worldDir = normalize(worldPos.xyz / worldPos.w - FrameBuffer::CameraPosAdjust[eyeIndex].xyz);

	// Horizon fade - only show near horizon
	float verticalAngle = abs(asin(worldDir.z));
	float horizonFade = 1.0 - saturate(verticalAngle / FarRainHorizonAngle);
	horizonFade = horizonFade * horizonFade;

	if (horizonFade <= 0.0)
		return;

	// === SPHERE 1: Tilted with wind (world space) ===
	float3 tiltedDir1 = ApplyWindTilt(worldDir, WindAngleRelative, WindTilt);
	float azimuth1 = atan2(tiltedDir1.y, tiltedDir1.x);
	float elevation1 = tiltedDir1.z;

	// Use elevation directly for Y (continuous scrolling, no wrap artifacts)
	// Time offset is applied to elevation before any scaling
	float scrolledElevation1 = elevation1 + Time * FarRainSpeed * 0.25;

	float2 noiseUV1;
	noiseUV1.x = (azimuth1 / 3.14159265 + 1.0) * 0.5 * FarRainScale * 100.0;  // 100:1 for very long thin streaks (4x longer)
	noiseUV1.y = scrolledElevation1 * FarRainScale;

	float noise1 = SampleNoiseYLinear(noiseUV1, 0);
	float rainStreak1 = (noise1 > 0.85) ? saturate((noise1 - 0.85) * 6.67) : 0.0;  // 0.85 threshold

	// === SPHERE 2: Additional 5 degree tilt for variation ===
	float3 tiltedDir2 = ApplyWindTilt(worldDir, WindAngleRelative, WindTilt + 0.0872665);  // +5 degrees
	float azimuth2 = atan2(tiltedDir2.y, tiltedDir2.x);
	float elevation2 = tiltedDir2.z;

	float scrolledElevation2 = elevation2 + Time * FarRainSpeed * 0.25 * 0.9;

	float2 noiseUV2;
	noiseUV2.x = (azimuth2 / 3.14159265 + 1.0) * 0.5 * FarRainScale * 100.0 * 1.3;
	noiseUV2.y = scrolledElevation2 * FarRainScale * 1.3;

	float noise2 = SampleNoiseYLinear(noiseUV2, 0.4);
	float rainStreak2 = (noise2 > 0.85) ? saturate((noise2 - 0.85) * 6.67) : 0.0;  // 0.85 threshold

	float finalRain = max(rainStreak1, rainStreak2 * 0.8);

	// Final opacity
	float opacity = finalRain * distanceFade * horizonFade * FarRainOpacity;

	if (opacity <= 0.001)
		return;

	// Blend rain with directional light color
	float4 currentColor = MainRW[dispatchID.xy];
	float3 rainColor = DirLightColor;
	currentColor.rgb += rainColor * opacity;
	MainRW[dispatchID.xy] = currentColor;
}
