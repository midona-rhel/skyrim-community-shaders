/**
 * DDGI Probe Ray Tracing - Compute Shader with Inline Ray Tracing
 *
 * Traces rays from probe positions to gather radiance and distance data.
 * Uses DXR 1.1 RayQuery (inline ray tracing) instead of traditional ray generation.
 *
 * Benefits over RayGeneration shader:
 * - No shader binding table needed for DDGI
 * - Simpler pipeline initialization
 * - All hit processing is inlined, avoiding separate ClosestHit shader
 *
 * Output is used by RTXGI's probe update compute shaders.
 */

#include "Raytracing/Includes/Types.hlsli"
#include "Raytracing/Includes/Registers.hlsli"
#include "Raytracing/Includes/Common.hlsli"
#include "Raytracing/Includes/RT/CommonRT.hlsli"
#include "Raytracing/Includes/RT/HitProcessing.hlsli"

// Define HLSL for RTXGI headers
#define HLSL 1

// Coordinate system: Left-handed Y-up (Skyrim)
#ifndef RTXGI_COORDINATE_SYSTEM
#define RTXGI_COORDINATE_SYSTEM 0
#endif

// DDGI SDK includes
#include "Common.hlsl"
#include "include/Common.hlsl"
#include "include/ProbeCommon.hlsl"  // Includes ProbeIndexing, ProbeRayCommon, ProbeOctahedral, ProbeDataCommon

// DDGI-specific resources for probe tracing
// These use the same names as DDGISampling.hlsli so we can reuse SampleDDGIIrradiance
// for multi-bounce GI. Define guard macros to prevent redeclaration.
#define DDGI_VOLUME_CONSTANTS_DECLARED
#define DDGI_PROBE_DATA_DECLARED
#define DDGI_PROBE_IRRADIANCE_DECLARED
#define DDGI_PROBE_DISTANCE_DECLARED
#define DDGI_BILINEAR_SAMPLER_DECLARED

// Volume constants - used by both probe tracing and sampling functions
ConstantBuffer<DDGIVolumeDescGPUPacked> DDGIVolumeConstants : register(b1, space4);

// Output: Probe ray data (radiance RGB, hit distance A)
RWTexture2DArray<float4> ProbeRayData : register(u3);

// Probe textures - needed for relocation offsets and multi-bounce sampling
Texture2DArray<float4> DDGIProbeIrradiance : register(t0, space4);
Texture2DArray<float4> DDGIProbeDistance   : register(t1, space4);
Texture2DArray<float4> DDGIProbeData       : register(t2, space4);
SamplerState DDGIBilinearSampler           : register(s1, space4);

// For multi-bounce GI from other probes (uses resources declared above)
#include "Raytracing/Includes/RT/DDGISampling.hlsli"

/**
 * Inline shadow ray trace using RayQuery.
 * Returns 1.0 if no hit (light visible), 0.0 if occluded.
 */
float TraceRayShadowInline(float3 origin, float3 direction, float tmax)
{
    RayDesc ray;
    ray.Origin = origin;
    ray.Direction = direction;
    ray.TMin = 0.01f;
    ray.TMax = tmax;

    RayQuery<RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_SKIP_PROCEDURAL_PRIMITIVES> rayQuery;
    rayQuery.TraceRayInline(Scene, RAY_FLAG_NONE, 0xFF, ray);
    rayQuery.Proceed();

    // If we hit nothing, light is visible
    return (rayQuery.CommittedStatus() == COMMITTED_NOTHING) ? 1.0f : 0.0f;
}

/**
 * Compute direct lighting using inline shadow rays.
 */
float3 ComputeDirectLightingInline(HitResult hit, inout uint randomSeed)
{
    float3 result = float3(0, 0, 0);

    // Directional light
    {
        float3 L = normalize(Frame.Directional.Vector);
        float NdotL = saturate(dot(hit.worldNormal, L));

        if (NdotL > 0.0f)
        {
            float shadow = TraceRayShadowInline(hit.worldPosition, L, 1e30f);
            result += NdotL * Frame.Directional.Color * hit.albedo * Frame.Diffuse * Frame.DDGISunBoost * shadow;
        }
    }

    // Point lights - sample one random light
    Instance instance = Instances[hit.instanceID];
    LightData lightData = instance.LightData;

    if (lightData.Count > 0)
    {
        uint lightIdx = min(uint(Random(randomSeed) * lightData.Count), lightData.Count - 1);
        uint lightID = lightData.GetID(lightIdx);
        Light light = Lights[lightID];

        float3 lightVector = light.Vector - hit.worldPosition;
        float lightDistance = length(lightVector);
        lightVector /= lightDistance;

        float attenuation = saturate(1.0f - lightDistance / light.Range);
        float NdotL = saturate(dot(hit.worldNormal, lightVector)) * attenuation;

        if (NdotL > 0.0f)
        {
            float shadow = TraceRayShadowInline(hit.worldPosition, lightVector, lightDistance);
            result += NdotL * float(lightData.Count) * light.Color * hit.albedo * Frame.Diffuse * shadow;
        }
    }

    return result;
}

/**
 * Store probe ray tracing result based on hit type.
 * Handles miss (sky), backface (inside geometry), and frontface hits.
 */
void StoreProbeRayResult(
    RWTexture2DArray<float4> rayData,
    uint3 coords,
    DDGIVolumeDescGPU volume,
    float4 result,      // RGB = radiance, A = hit distance (-1 = miss)
    float3 rayDirection,
    int rayIndex
) {
    float hitDistance = result.a;

    // Miss - sample sky and store large distance
    if (hitDistance < 0.0f) {
        float3 dir = normalize(rayDirection);
        // Spherical UV mapping: longitude -> [0,1], latitude -> [0,1]
        float2 skyUV = float2(
            atan2(dir.x, dir.z) / (2.0f * Math::PI) + 0.5f,
            acos(saturate(dir.y)) / Math::PI
        );
        float3 skyRadiance = SkyHemisphere.SampleLevel(BaseSampler, skyUV, 0).rgb;
        DDGIStoreProbeRayMiss(rayData, coords, volume, skyRadiance);
        return;
    }

    // Backface hit - probe is inside geometry, used for relocation
    if (result.r < -0.5f) {  // We use result.r < 0 as backface marker
        DDGIStoreProbeRayBackfaceHit(rayData, coords, volume, hitDistance);
        return;
    }

    // Fixed rays (first 32) - only distance for relocation/classification
    bool isFixedRay = (volume.probeRelocationEnabled || volume.probeClassificationEnabled)
                      && rayIndex < RTXGI_DDGI_NUM_FIXED_RAYS;
    if (isFixedRay) {
        DDGIStoreProbeRayFrontfaceHit(rayData, coords, volume, hitDistance);
        return;
    }

    // Normal frontface hit - store radiance and distance
    DDGIStoreProbeRayFrontfaceHit(rayData, coords, volume, saturate(result.rgb), hitDistance);
}

[numthreads(8, 8, 1)]
void main(uint3 DTid : SV_DispatchThreadID)
{
    // Dispatch dimensions match RayData texture layout
    int rayIndex = DTid.x;
    int probePlaneIndex = DTid.y;
    int planeIndex = DTid.z;

    // Unpack volume descriptor
    DDGIVolumeDescGPU volume = UnpackDDGIVolumeDescGPU(DDGIVolumeConstants);

    // Early bounds check
    int probesPerPlane = DDGIGetProbesPerPlane(volume.probeCounts);
    if (probePlaneIndex >= probesPerPlane)
        return;
    if (rayIndex >= volume.probeNumRays)
        return;

    // Calculate linear probe index
    int probeIndex = (planeIndex * probesPerPlane) + probePlaneIndex;

    // Get probe grid coordinates from linear index
    int3 probeCoords = DDGIGetProbeCoords(probeIndex, volume);

    // Adjust probe index for scrolling (if enabled)
    probeIndex = DDGIGetScrollingProbeIndex(probeCoords, volume);

    // Early out: skip tracing for inactive probes (except for fixed rays needed for classification)
    float probeState = DDGILoadProbeState(probeIndex, DDGIProbeData, volume);
    if (probeState == RTXGI_DDGI_PROBE_STATE_INACTIVE && rayIndex >= RTXGI_DDGI_NUM_FIXED_RAYS)
        return;

    // Get output coordinates using SDK function
    uint3 outputCoords = DDGIGetRayDataTexelCoords(rayIndex, probeIndex, volume);

    // Get probe world position (with relocation offsets if enabled)
    float3 probeWorldPosition = DDGIGetProbeWorldPosition(probeCoords, volume, DDGIProbeData);

    // Get ray direction using SDK function (handles fixed rays correctly)
    float3 probeRayDirection = DDGIGetProbeRayDirection(rayIndex, volume);

    // Initialize random seed for light sampling
    uint randomSeed = InitRandomSeed(uint2(rayIndex, probeIndex), uint2(volume.probeNumRays, volume.probeCounts.x * volume.probeCounts.y * volume.probeCounts.z), Frame.FrameCount);

    // Setup ray for inline tracing
    RayDesc ray;
    ray.Origin = probeWorldPosition;
    ray.Direction = probeRayDirection;
    ray.TMin = 0.0f;  // Probes have no geometry, no self-intersection possible
    ray.TMax = volume.probeMaxRayDistance;

    // Trace using RayQuery (inline ray tracing)
    // Instance mask bits:
    //   Bit 0 (0x01): Static geometry - hit by DDGI probes
    //   Bit 1 (0x02): Skinned/dynamic geometry - hit only by screen-space GI
    // Using 0x01 ensures probes only trace against static world geometry,
    // avoiding temporal instability from animated meshes.
    RayQuery<RAY_FLAG_NONE> rayQuery;
    rayQuery.TraceRayInline(Scene, RAY_FLAG_NONE, 0x01, ray);
    rayQuery.Proceed();

    float4 result = float4(0, 0, 0, -1.0f);  // Default: miss (negative distance)

    if (rayQuery.CommittedStatus() == COMMITTED_TRIANGLE_HIT)
    {
        float hitT = rayQuery.CommittedRayT();
        bool isFrontFace = rayQuery.CommittedTriangleFrontFace();

        if (!isFrontFace)
        {
            // Backface hit - probe is inside geometry
            // Mark with negative radiance as signal, positive distance
            result = float4(-1.0f, 0.0f, 0.0f, hitT);
        }
        else
        {
            // Frontface hit - process hit and compute radiance
            uint instanceID = rayQuery.CommittedInstanceIndex();
            uint geometryIndex = rayQuery.CommittedGeometryIndex();
            uint primitiveID = rayQuery.CommittedPrimitiveIndex();
            float2 barycentrics = rayQuery.CommittedTriangleBarycentrics();

            // Get transform matrix
            float3x4 objectToWorld = rayQuery.CommittedObjectToWorld3x4();

            // Compute mesh ID (same as InstanceID() + GeometryIndex() in traditional RT)
            uint meshID = rayQuery.CommittedInstanceID() + geometryIndex;

            // Process hit to get material/geometry info
            HitResult hit = ProcessHit(
                instanceID,
                meshID,
                primitiveID,
                barycentrics,
                ray.Origin,
                ray.Direction,
                hitT,
                isFrontFace ? HIT_KIND_TRIANGLE_FRONT_FACE : HIT_KIND_TRIANGLE_BACK_FACE,
                objectToWorld
            );

            // Compute radiance at hit point
            float3 radiance = hit.emissive;

            // Add direct lighting
            radiance += ComputeDirectLightingInline(hit, randomSeed);

            // Add multi-bounce from other probes (recursive GI)
            // Following NVIDIA's approach: radiance = direct + (albedo/PI * irradiance)
            float3 viewDir = normalize(-ray.Direction);
            float3 irradiance = SampleDDGIIrradiance(hit.worldPosition, hit.worldNormal, viewDir);

            // Clamp albedo to prevent energy amplification (max 0.9 per NVIDIA recommendation)
            float3 clampedAlbedo = min(hit.albedo, float3(0.9f, 0.9f, 0.9f));
            radiance += (clampedAlbedo / Math::PI) * irradiance;

            result = float4(radiance, hitT);
        }
    }

    // Store result based on hit type
    StoreProbeRayResult(ProbeRayData, outputCoords, volume, result, probeRayDirection, rayIndex);
}
