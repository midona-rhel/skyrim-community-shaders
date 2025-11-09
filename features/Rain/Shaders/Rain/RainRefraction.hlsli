// Rain Refraction Feature Shader
// This shader provides realistic light refraction through rain particles

namespace RainRefraction
{
	// Textures bound by the feature (t64, t65)
	// TexRefractionSceneColor - Scene color copy before particles (t64)
	// TexRefractionNormal - Rain normal texture for distortion (t65)

	// Helper function to calculate refraction offset
	// Note: Main refraction logic is in Particle.hlsl pixel shader
	// This file can be extended with additional helper functions if needed

	// Example helper (currently unused, showing pattern):
	float2 CalculateRefractionOffset(float2 normal, float strength)
	{
		return normal * strength * 0.05;
	}
}
