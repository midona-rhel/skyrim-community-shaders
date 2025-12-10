/**
 * HitProcessing.hlsli - Shared hit processing for ray tracing
 *
 * This file contains common hit processing functions used by both:
 * - GI/ClosestHit.hlsl (traditional RT pipeline)
 * - DDGI/ProbeTraceCS.hlsl (inline RT in compute shader)
 *
 * The goal is to avoid duplicating the complex material sampling and lighting
 * logic between these two shaders.
 */

#ifndef HIT_PROCESSING_HLSLI
#define HIT_PROCESSING_HLSLI

#include "Raytracing/Includes/Types.hlsli"
#include "Raytracing/Includes/Registers.hlsli"
#include "Raytracing/Includes/Common.hlsli"

#include "Common/Game.hlsli"
#include "Common/Color.hlsli"

/**
 * Result of processing a ray hit against scene geometry.
 * Contains all interpolated vertex data and sampled material properties.
 */
struct HitResult
{
    float3 worldPosition;   // Hit point in world space
    float3 worldNormal;     // Interpolated and transformed normal
    float3 worldTangent;    // Interpolated and transformed tangent
    float3 worldBitangent;  // Interpolated and transformed bitangent
    float3 albedo;          // Base color (gamma corrected to linear)
    float3 emissive;        // Self-illumination from materials
    float4 vertexColor;     // Interpolated vertex color
    float hitT;             // Ray parameter at hit point
    uint hitKind;           // HIT_KIND_TRIANGLE_FRONT_FACE or HIT_KIND_TRIANGLE_BACK_FACE
    uint instanceID;        // Instance index in TLAS
    uint meshID;            // Geometry index within instance
};

/**
 * Compute barycentric coordinates from RayQuery committed barycentrics.
 * DXR returns (u, v) where w = 1 - u - v.
 */
float3 ComputeBarycentrics(float2 bary)
{
    return float3(1.0f - bary.x - bary.y, bary.x, bary.y);
}

/**
 * Interpolate vertex attributes using barycentric coordinates.
 * These match the Geometry.hlsli functions but don't require BuiltInTriangleIntersectionAttributes.
 */
float2 InterpolateFloat2(half2 a, half2 b, half2 c, float3 bary)
{
    return a * bary.x + b * bary.y + c * bary.z;
}

float3 InterpolateFloat3(float3 a, float3 b, float3 c, float3 bary)
{
    return a * bary.x + b * bary.y + c * bary.z;
}

float3 InterpolateHalf3(half3 a, half3 b, half3 c, float3 bary)
{
    return a * bary.x + b * bary.y + c * bary.z;
}

float4 InterpolateHalf4(half4 a, half4 b, half4 c, float3 bary)
{
    return a * bary.x + b * bary.y + c * bary.z;
}

/**
 * Process a ray hit and extract all material/geometry information.
 *
 * This is the core hit processing logic extracted from ClosestHit.hlsl.
 * It handles vertex interpolation, normal/tangent transformation, texture
 * sampling, and emissive calculation.
 *
 * @param instanceID  The instance index from RayQuery or InstanceIndex()
 * @param meshID      The geometry index (InstanceID + GeometryIndex)
 * @param primitiveID The triangle index within the geometry
 * @param barycentrics The barycentric coordinates (u, v) from intersection
 * @param rayOrigin   The ray origin in world space
 * @param rayDirection The ray direction in world space
 * @param hitT        The ray parameter at the hit point
 * @param hitKind     HIT_KIND_TRIANGLE_FRONT_FACE or HIT_KIND_TRIANGLE_BACK_FACE
 * @param objectToWorld The 3x4 object-to-world transform matrix
 * @return HitResult with all processed hit information
 */
HitResult ProcessHit(
    uint instanceID,
    uint meshID,
    uint primitiveID,
    float2 barycentrics,
    float3 rayOrigin,
    float3 rayDirection,
    float hitT,
    uint hitKind,
    float3x4 objectToWorld
)
{
    HitResult result;
    result.hitT = hitT;
    result.hitKind = hitKind;
    result.instanceID = instanceID;
    result.meshID = meshID;
    result.worldPosition = rayOrigin + rayDirection * hitT;

    // Get barycentric weights
    float3 bary = ComputeBarycentrics(barycentrics);

    // Get triangle vertices
    Triangle tri = Triangles[meshID][primitiveID];
    StructuredBuffer<Vertex> vertices = Vertices[meshID];
    Vertex v0 = vertices[tri.x];
    Vertex v1 = vertices[tri.y];
    Vertex v2 = vertices[tri.z];

    // Get material
    Material material = Materials[meshID];

    // Compute texture coordinates
    float2 texCoord = material.TexCoord(InterpolateFloat2(v0.Texcoord0, v1.Texcoord0, v2.Texcoord0, bary));

    // Transform normals and tangents to world space
    float3x3 objectToWorld3x3 = (float3x3)objectToWorld;

    result.worldNormal = normalize(mul(objectToWorld3x3, InterpolateFloat3(v0.Normal, v1.Normal, v2.Normal, bary)));
    result.worldTangent = normalize(mul(objectToWorld3x3, InterpolateFloat3(v0.Tangent, v1.Tangent, v2.Tangent, bary)));
    result.worldBitangent = normalize(mul(objectToWorld3x3, InterpolateFloat3(v0.Bitangent, v1.Bitangent, v2.Bitangent, bary)));

    // Interpolate vertex color
    result.vertexColor = InterpolateHalf4(v0.Color.unpack(), v1.Color.unpack(), v2.Color.unpack(), bary);

    // Sample base texture
    Texture2D baseTexture = Textures[NonUniformResourceIndex(material.BaseTexture)];
    float3 base = baseTexture.SampleLevel(BaseSampler, texCoord, 0).rgb;

    // Convert to linear space and apply vertex color
    result.albedo = Color::GammaToLinear(base) * result.vertexColor.rgb;

    // Calculate emissive - check if real glow texture exists (indices 0-1 are fallback)
    if (material.EffectTexture > 1) {
        Texture2D effectTexture = Textures[NonUniformResourceIndex(material.EffectTexture)];
        float3 effect = effectTexture.SampleLevel(BaseSampler, texCoord, 0).rgb;
        // When glow texture exists, use it directly - emissiveMult is often 0 in Skyrim
        // The glow texture itself indicates emissive content
        float emissiveScale = material.EffectColor.a > 0.0f ? material.EffectColor.a : 1.0f;
        result.emissive = Color::GammaToLinear(effect) * material.EffectColor.rgb * emissiveScale;
    } else {
        // No glow texture - use EffectColor directly (rgb = color, a = multiplier)
        result.emissive = material.EffectColor.rgb * material.EffectColor.a;
    }

    return result;
}

// The following functions require TraceRay intrinsics from Rays.hlsli
// They are only available in traditional RT shader stages (raygen, closest hit, miss)
// NOT in compute shaders - compute shaders should use inline versions (RayQuery)
#ifdef RAYS_HLSI

/**
 * Compute direct lighting contribution from the directional light.
 * Uses Lambertian shading for diffuse-only (suitable for DDGI probes).
 * NOTE: Requires traditional RT pipeline (TraceRay). For compute shaders, use inline version.
 *
 * @param hit        The processed hit result
 * @param randomSeed Random seed for shadow ray sampling
 * @return Direct lighting radiance from directional light
 */
float3 ComputeDirectLightingLambert(HitResult hit, inout uint randomSeed)
{
    float3 L = normalize(Frame.Directional.Vector);
    float NdotL = saturate(dot(hit.worldNormal, L));

    if (NdotL <= 0.0f)
        return float3(0, 0, 0);

    // Shadow ray
    float shadow = TraceRayShadow(Scene, hit.worldPosition, L);

    return NdotL * Frame.Directional.Color * hit.albedo * Frame.Diffuse * shadow;
}

/**
 * Compute direct lighting contribution from point lights.
 * Uses importance sampling to select one random light.
 * NOTE: Requires traditional RT pipeline (TraceRay). For compute shaders, use inline version.
 *
 * @param hit        The processed hit result
 * @param lightData  Light data from the instance
 * @param randomSeed Random seed for light selection and shadow rays
 * @return Direct lighting radiance from point lights
 */
float3 ComputePointLightsLambert(HitResult hit, LightData lightData, inout uint randomSeed)
{
    if (lightData.Count == 0)
        return float3(0, 0, 0);

    // Sample one random light
    uint lightIdx = min(uint(Random(randomSeed) * lightData.Count), lightData.Count - 1);
    uint lightID = lightData.GetID(lightIdx);
    Light light = Lights[lightID];

    float3 lightVector = light.Vector - hit.worldPosition;
    float lightDistance = length(lightVector);
    lightVector /= lightDistance;

    // Linear attenuation
    float attenuation = saturate(1.0f - lightDistance / light.Range);

    float NdotL = saturate(dot(hit.worldNormal, lightVector)) * attenuation;
    NdotL *= float(lightData.Count) * TraceRayShadowFinite(Scene, hit.worldPosition, lightVector, lightDistance);

    return NdotL * light.Color * hit.albedo * Frame.Diffuse;
}

#endif // RAYS_HLSI

#endif // HIT_PROCESSING_HLSLI
