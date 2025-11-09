#include "Common/FrameBuffer.hlsli"
#include "Common/VR.hlsli"
#include "Common/SharedData.hlsli"

#if defined(RAIN_FEATURE)
#	if defined(LIGHT_LIMIT_FIX)
#		include "LightLimitFix/LightLimitFix.hlsli"
#	endif
#	if defined(ISL) && defined(LIGHT_LIMIT_FIX)
#		include "InverseSquareLighting/InverseSquareLighting.hlsli"
#	endif
#	include "Common/Color.hlsli"
#endif

struct VS_INPUT
{
	float4 Position : POSITION0;
#if !defined(ENVCUBE)
	float4 Normal : NORMAL0;
#endif
	float4 TexCoord0 : TEXCOORD0;
#if defined(ENVCUBE)
	float4
#else
	int4
#endif
		TexCoord1 : TEXCOORD1;
#if defined(VR)
	uint InstanceID : SV_INSTANCEID;
#endif  // VR
};

struct VS_OUTPUT
{
	float4 Position : SV_POSITION0;
	float4 Color : COLOR0;
	float2 TexCoord0 : TEXCOORD0;
#if defined(ENVCUBE)
	float4 PrecipitationOcclusionTexCoord : TEXCOORD1;
#endif
#if defined(VR)
	float ClipDistance : SV_ClipDistance0;  // o11
	float CullDistance : SV_CullDistance0;  // p11
	uint EyeIndex : EYEIDX0;
#endif  // VR
#if defined(RAIN_FEATURE) && defined(RAIN)
	float3 WorldPosition : TEXCOORD2;  // World space position for lighting distance calculations
#endif
};

#ifdef VSHADER
cbuffer PerTechnique : register(b0)
{
	float2 ScaleAdjust : packoffset(c0);
};

cbuffer PerGeometry : register(b2)
{
#	if !defined(VR)
	row_major float4x4 WorldViewProj[1];  // 0
	row_major float4x4 WorldView[1];      // 4
#	else
	row_major float4x4 WorldViewProj[2];  // 0
	row_major float4x4 WorldView[2];      // 8
#	endif
#	if defined(ENVCUBE)
	row_major float4x4 PrecipitationOcclusionWorldViewProj;  // 8, 16
#	endif
	float4 fVars0;        // 8, 16 ENVCUBE 12, 20
	float4 fVars1;        // 9, 17 ENVCUBE 13, 21
	float4 fVars2;        // 10, 18 ENVCUBE 14, 22
	float4 fVars3;        // 11, 19 ENVCUBE 15, 23
	float4 fVars4;        // 12, 20 ENVCUBE 16, 24
	float4 Color1;        // 13, 21 ENVCUBE 17, 25
	float4 Color2;        // 14, 22 ENVCUBE 18, 26
	float4 Color3;        // 15, 23 ENVCUBE 19, 27
	float4 Velocity;      // 16, 24 ENVCUBE 20, 28
	float4 Acceleration;  // 17, 25 ENVCUBE 21, 29
	float4 Wind;          // 18, 26 ENVCUBE 22, 30
}

float2x2 GetRotationMatrix(float angle)
{
	float sine, cosine;
	sincos(angle, sine, cosine);

	return float2x2(float2(cosine, -sine), float2(sine, cosine));
}

VS_OUTPUT main(VS_INPUT input)
{
	VS_OUTPUT vsout;

	uint eyeIndex = Stereo::GetEyeIndexVS(
#	if defined(VR)
		input.InstanceID
#	endif
	);

#	if defined(ENVCUBE)
#		if defined(RAIN)
	float2 positionOffset = input.TexCoord1.xy;
#			if defined(RAIN_FEATURE)
	positionOffset *= SharedData::rainSettings.RainWidth;
#			endif
#		else
	float2x2 rotationMatrix = GetRotationMatrix(fVars0.w);
	float2 positionOffset = mul(rotationMatrix, input.TexCoord1.xy) * ScaleAdjust + mul(rotationMatrix, input.TexCoord1.zw);
#		endif

	float3 normalizedPosition = (fVars0.xyz + input.Position.xyz) / fVars2.xxx;
	normalizedPosition = normalizedPosition >= -normalizedPosition ? frac(abs(normalizedPosition)) :
	                                                                 -frac(abs(normalizedPosition));

	float4 msPosition;
	msPosition.xyz = normalizedPosition * fVars2.xxx + (-(fVars2.x * 0.5).xxx + fVars1.xyz);
	msPosition.w = 1;

	float4 viewPosition = mul(WorldViewProj[eyeIndex], msPosition);
#		if defined(RAIN)
	float rainLengthScale = 1.0;
#			if defined(RAIN_FEATURE)
	rainLengthScale = SharedData::rainSettings.RainLength;
#			endif
	float4 adjustedMsPosition = msPosition - float4(Velocity.xyz * rainLengthScale, 0);
	float positionBlendParam = 0.5 * (1 + input.TexCoord1.y);
	float4 adjustedViewPosition = mul(WorldViewProj[eyeIndex], adjustedMsPosition);
	float4 finalViewPosition = lerp(adjustedViewPosition, viewPosition, positionBlendParam);
#		else
	float4 finalViewPosition = viewPosition;
#		endif
	vsout.Position.xy = positionOffset + finalViewPosition.xy;
	vsout.Position.zw = finalViewPosition.zw;

#		if defined(RAIN_FEATURE) && defined(RAIN)
	// Pass world position directly for lighting distance calculations
	// msPosition.xyz is the particle's position in world space
	vsout.WorldPosition = msPosition.xyz;
#		endif

	vsout.Color.xyz = 1.0.xxx;
	vsout.Color.w = fVars1.w;

	vsout.TexCoord0.xy = input.TexCoord0.xy;

	float4 precipitationOcclusionTexCoord = mul(PrecipitationOcclusionWorldViewProj, msPosition);
	precipitationOcclusionTexCoord.y = -precipitationOcclusionTexCoord.y;
	vsout.PrecipitationOcclusionTexCoord = precipitationOcclusionTexCoord;
#	else
	float tmp2 = input.Normal.w * input.Position.w;
	float tmp1 = tmp2 / fVars0.y;

	float uvScale1, uvScale2, tmp3, tmp4;
	if (tmp1 > fVars2.w) {
		uvScale1 = fVars2.y;
		uvScale2 = 0;
		tmp3 = fVars2.w;
		tmp4 = 1;
	} else if (tmp1 > fVars2.z) {
		uvScale1 = fVars2.x;
		uvScale2 = fVars2.y;
		tmp3 = fVars2.z;
		tmp4 = fVars2.w;
	} else {
		uvScale1 = 0;
		uvScale2 = fVars2.x;
		tmp3 = 0;
		tmp4 = fVars2.z;
	}
	float uvScaleParam = (tmp1 - tmp3) / (tmp4 - tmp3);
	float uvScale = lerp(uvScale1, uvScale2, uvScaleParam);

	vsout.TexCoord0.xy = fVars4.xy * input.TexCoord1.xy;

	float2 uv1 = (input.TexCoord1.zw * 2.0.xx - 1.0.xx) * uvScale;
	float uvAngle = input.TexCoord0.y * input.Position.w + input.TexCoord0.x;
	float2x2 rotationMatrix = GetRotationMatrix(uvAngle);
	float2 positionOffset = mul(rotationMatrix, uv1);

	float4 msPosition;
	msPosition.xyz = -fVars3.xyz +
	                 (((input.Normal.xyz * fVars0.www + Acceleration.xyz) * (tmp2 * tmp2)) * 0.5 +
						 (((fVars0.zzz * input.Normal.xyz) * input.TexCoord0.zzz +
							  (normalize(-Wind.xyz + input.Position.xyz) * Wind.www + Velocity.xyz)) *
								 tmp2 +
							 input.Position.xyz));
	msPosition.w = 1;

	float4 viewPosition = mul(WorldViewProj[eyeIndex], msPosition);
	vsout.Position.xy = positionOffset * ScaleAdjust + viewPosition.xy;
	vsout.Position.zw = viewPosition.zw;

	float4 color1, color2;
	float colorTmp1, colorTmp2;
	if (tmp1 > fVars1.z) {
		color1 = Color3.xyzw;
		color2 = float4(Color3.xyz, 0);
		colorTmp1 = fVars1.z;
		colorTmp2 = 1;
	} else if (tmp1 > fVars1.y) {
		color1 = Color2.xyzw;
		color2 = Color3.xyzw;
		colorTmp1 = fVars1.y;
		colorTmp2 = fVars1.z;
	} else if (tmp1 > fVars1.x) {
		color1 = Color1.xyzw;
		color2 = Color2.xyzw;
		colorTmp1 = fVars1.x;
		colorTmp2 = fVars1.y;
	} else {
		color1 = float4(Color1.xyz, 0);
		color2 = Color1.xyzw;
		colorTmp1 = 0;
		colorTmp2 = fVars1.x;
	}
	float colorParam = (tmp1 - colorTmp1) / (colorTmp2 - colorTmp1);
	float4 color = lerp(color1, color2, colorParam);

	vsout.Color.w = fVars3.w * color.w;
	vsout.Color.xyz = color.xyz;
#	endif

#	ifdef VR
	vsout.EyeIndex = eyeIndex;
	Stereo::VR_OUTPUT VRout = Stereo::GetVRVSOutput(vsout.Position, eyeIndex);
	vsout.Position = VRout.VRPosition;
	vsout.ClipDistance.x = VRout.ClipDistance;
	vsout.CullDistance.x = VRout.CullDistance;
#	endif  // VR
	return vsout;
}
#endif

typedef VS_OUTPUT PS_INPUT;

struct PS_OUTPUT
{
	float4 Color : SV_Target0;
#if defined(RAIN_FEATURE) && defined(RAIN)
	float4 RainNormals : SV_Target3;
	float4 RainLight : SV_Target4;
#endif
};

#ifdef PSHADER
SamplerState SampSourceTexture : register(s0);
#	if defined(GRAYSCALE_TO_COLOR) || defined(GRAYSCALE_TO_ALPHA)
SamplerState SampGrayscaleTexture : register(s1);
#	endif
#	if defined(ENVCUBE)
SamplerState SampPrecipitationOcclusionTexture : register(s2);
SamplerState SampUnderwaterMask : register(s3);
#	endif

Texture2D<float4> TexSourceTexture : register(t0);
#	if defined(GRAYSCALE_TO_COLOR) || defined(GRAYSCALE_TO_ALPHA)
Texture2D<float4> TexGrayscaleTexture : register(t1);
#	endif
#	if defined(ENVCUBE)
Texture2D<float4> TexPrecipitationOcclusionTexture : register(t2);
Texture2D<float4> TexUnderwaterMask : register(t3);
#	endif
#	if defined(RAIN_FEATURE) && defined(RAIN)
Texture2D<float4> TexRainNormals : register(t65);
TextureCube<float3> EnvReflectionsTexture : register(t30);
SamplerState SampEnvReflections : register(s14);
#	endif

cbuffer PerGeometry : register(b2)
{
	float ColorScale : packoffset(c0);
	float3 TextureSize : packoffset(c1);
};

PS_OUTPUT main(PS_INPUT input)
{
	PS_OUTPUT psout;

#	if !defined(VR)
	uint eyeIndex = 0;
#	else
	uint eyeIndex = input.EyeIndex;
#	endif  // !VR

#	if defined(ENVCUBE)
	float2 precipitationOcclusionUV = (input.PrecipitationOcclusionTexCoord.xy * 0.5 + 0.5) * TextureSize.x;
#		ifdef VR
	precipitationOcclusionUV *= FrameBuffer::DynamicResolutionParams1.x;  // only difference in VR
#		endif
	float precipitationOcclusion = -input.PrecipitationOcclusionTexCoord.z + TexPrecipitationOcclusionTexture.Load(float3(precipitationOcclusionUV, 0)).x;
	float2 underwaterMaskUv = TextureSize.yz * input.Position.xy;
	float underwaterMask = TexUnderwaterMask.Sample(SampUnderwaterMask, underwaterMaskUv).x;
	if (precipitationOcclusion - underwaterMask < 0) {
		discard;
	}
#	endif

	float4 sourceColor = TexSourceTexture.Sample(SampSourceTexture, input.TexCoord0);
	float4 baseColor = input.Color * sourceColor;
#	if defined(GRAYSCALE_TO_COLOR)
	float3 grayScaleColor =
		TexGrayscaleTexture.Sample(SampGrayscaleTexture, float2(sourceColor.y, input.Color.x)).xyz;
	baseColor.xyz = grayScaleColor;
#	endif
#	if defined(GRAYSCALE_TO_ALPHA)
	float grayScaleAlpha =
		TexGrayscaleTexture.Sample(SampGrayscaleTexture, float2(sourceColor.w, input.Color.w)).w;
	baseColor.w = grayScaleAlpha;
#	endif

	psout.Color.xyz = ColorScale * baseColor.xyz;
	psout.Color.w = baseColor.w;

#	if defined(RAIN_FEATURE)
#		if defined(RAIN)
	// Rain particles: output screen-space normals for refraction
	// Don't draw the particle texture - only output to light/normal buffers
	if (SharedData::rainSettings.EnableRain) {
		float4 rainNormalSample = TexRainNormals.Sample(SampSourceTexture, input.TexCoord0);

		// Discard if RG is near 0.5 (center of raindrop = no refraction, no visible rain)
		float2 normalOffset = abs(rainNormalSample.rg - 0.5);
		if (normalOffset.x < 0.01 && normalOffset.y < 0.01) {
			discard;
		}

		// Don't draw the particle texture
		psout.Color = float4(0, 0, 0, 0);

		float2 screenSpaceNormal = rainNormalSample.rg;
		float depth = input.Position.z / input.Position.w;
		float mask = input.Color.w;
		psout.RainNormals = float4(screenSpaceNormal, depth, mask);

		// Calculate local light contribution
		// Treat particles as geometry - the normal texture gives us the surface normal
		// We work in view space since the normal is naturally screen-aligned
		float3 lightColor = 0.0;

		// Convert normal from [0,1] to [-1,1]
		float2 normalDir = (screenSpaceNormal - 0.5) * 2.0;

		// Reconstruct Z from sphere normal: x² + y² + z² = 1, so z = sqrt(1 - x² - y²)
		float normalLenSq = dot(normalDir, normalDir);
		float cosTheta = sqrt(saturate(1.0 - normalLenSq));

		// Fresnel: F = F0 + (1-F0)(1-cosTheta)^power
		float fresnelF0 = SharedData::rainSettings.FresnelF0;
		float fresnelPower = SharedData::rainSettings.FresnelPower;
		float fresnel = fresnelF0 + (1.0 - fresnelF0) * pow(1.0 - cosTheta, fresnelPower);

		// Get strength multipliers from settings (UI values are 0-2, multiply by 2 for internal use)
		float reflectionStrength = SharedData::rainSettings.ReflectionStrength * 2.0;
		float specularPower = SharedData::rainSettings.SpecularPower;
		float skyLightStrength = SharedData::rainSettings.SkyLightStrength * 2.0;

		// Get world position of particle
		float3 particleWorldPos = input.WorldPosition;

		// Convert to view space for light calculations
		float3 viewPositionVS = FrameBuffer::WorldToView(particleWorldPos, true, eyeIndex);

		// Billboard normal: X = right, Y = up, Z = toward camera
		// For reflection off a sphere facing camera, reflect (0,0,-1) around normal
		float3 N = normalize(float3(normalDir.x, normalDir.y, cosTheta));
		float3 reflectDir = reflect(float3(0, 0, -1), N);  // Reflect incoming view ray

		// Transform reflection direction from view space to world space
		// Fix coordinate mapping: negate X (mirrored), negate Y (upside down), negate Z (front/back)
		float3 correctedDir = float3(-reflectDir.x, -reflectDir.y, -reflectDir.z);
		float3 R = mul((float3x3)FrameBuffer::CameraViewInverse[eyeIndex], correctedDir);

		// Sample environment cubemap for sky/environment reflection
		float3 envColor = EnvReflectionsTexture.SampleLevel(SampEnvReflections, R, 0).rgb;
		envColor = Color::GammaToLinear(envColor);
		lightColor = envColor * fresnel * mask * skyLightStrength;

#			if defined(LIGHT_LIMIT_FIX)
		// Get screen UV for cluster lookup
		float2 screenUV = input.Position.xy / SharedData::BufferDim.xy;

		// Get light cluster
		uint clusterIndex = 0;
		if (LightLimitFix::GetClusterIndex(screenUV, abs(viewPositionVS.z), clusterIndex)) {
			uint lightCount = LightLimitFix::lightGrid[clusterIndex].lightCount;
			uint lightOffset = LightLimitFix::lightGrid[clusterIndex].offset;

			[loop] for (uint i = 0; i < lightCount; i++)
			{
				uint clusteredLightIndex = LightLimitFix::lightList[lightOffset + i];
				LightLimitFix::Light light = LightLimitFix::lights[clusteredLightIndex];

				if (LightLimitFix::IsLightIgnored(light) || (light.lightFlags & LightLimitFix::LightFlags::Shadow)) {
					continue;
				}

				// Calculate distance in WORLD SPACE for proper attenuation
				// This is the actual distance from particle to light
				float3 toLightWS = light.positionWS[eyeIndex].xyz - particleWorldPos;
				float lightDist = length(toLightWS);

				// Get light direction in VIEW SPACE for N dot L calculation
				// (since our normal N is in view space)
				float3 lightPosVS = FrameBuffer::WorldToView(light.positionWS[eyeIndex].xyz, true, eyeIndex);
				float3 toLightVS = lightPosVS - viewPositionVS;
				float3 L = normalize(toLightVS);

#				if defined(ISL)
				float intensityMultiplier = InverseSquareLighting::GetAttenuation(lightDist, light);
#				else
				float intensityFactor = saturate(lightDist / light.radius);
				float intensityMultiplier = 1.0 - intensityFactor * intensityFactor;
#				endif

				// Specular reflection only - no transmission/refraction component
				// Reflection: bright highlight when light reflects toward camera
				float3 R_spec = reflect(-L, N);
				float RdotV = saturate(dot(R_spec, float3(0, 0, 1)));  // V in view space is (0,0,1)
				float reflectSpecular = pow(RdotV, specularPower);

				// Fresnel controls reflection intensity
				float lighting = reflectSpecular * fresnel * reflectionStrength;

				lightColor += light.color.xyz * intensityMultiplier * lighting;
			}
		}
#			endif

		psout.RainLight = float4(lightColor, mask);
	}
#		endif
#	endif

	return psout;
}
#endif
