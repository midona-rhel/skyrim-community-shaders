#pragma once

#include <winrt/base.h>

struct Rain : Feature
{
public:
	struct alignas(16) Settings
	{
		uint EnableRain = true;
		float RefractionStrength = 1.0f;      // 0-2 range, multiplied by 50 in shader
		float RainWidth = 3.0f;
		float RainLength = 1.0f;

		float LightOpacity = 1.0f;            // 0-2 UI, multiplied by 2 in code
		float FresnelPower = 5.0f;            // Physically correct default
		float FresnelF0 = 0.02f;              // Water at normal incidence
		float IOR = 1.33f;                    // Index of refraction (water = 1.33)

		float ReflectionStrength = 1.0f;      // 0-2 UI, multiplied by 2 in code
		float SpecularPower = 12.0f;          // 0-25 range
		float SkyLightStrength = 1.0f;        // 0-2 UI, multiplied by 2 in code
		float pad1 = 0.0f;

		// Far Rain settings (screen-space)
		uint EnableFarRain = true;
		float FarRainDistance = 2000.0f;      // Distance where effect starts
		float FarRainMaxDistance = 8000.0f;   // Distance where effect is full strength
		float FarRainSpeed = 2.0f;            // Scroll speed
	};

	Settings settings;

	bool overrideParticle = false;
	bool isRainParticle = false;
	void ParticleShaderHacks();

	Texture2D* rainNormalsBuffer = nullptr;  // Buffer to capture rain normals/data
	Texture2D* rainLightBuffer = nullptr;    // Buffer to capture local light contribution
	Texture2D* rainNormalsTexture = nullptr;  // Texture for normal maps
	Texture2D* mainCopy = nullptr;  // Copy of main render target for refraction

	ID3D11ComputeShader* refractionCS = nullptr;
	ID3D11ComputeShader* GetComputeShaderRefraction();

	struct alignas(16) RefractionCB
	{
		float RefractionStrength;
		float LightOpacity;
		float IOR;
		float pad;
	};
	ConstantBuffer* refractionCB = nullptr;

	// Far Rain resources
	ID3D11ComputeShader* farRainCS = nullptr;
	ID3D11ComputeShader* GetComputeShaderFarRain();
	ID3D11ShaderResourceView* blueNoiseSRV = nullptr;
	ID3D11SamplerState* wrapSampler = nullptr;

	struct alignas(16) FarRainCB
	{
		float FarRainDistance;
		float FarRainMaxDistance;
		float FarRainOpacity;
		float FarRainSpeed;

		float FarRainStretch;
		float FarRainScale;
		float FarRainHorizonAngle;
		float Time;

		float BufferDimX;
		float BufferDimY;
		float WindAngleRelative;  // Wind direction relative to player view (radians)
		float WindTilt;           // Tilt angle based on wind strength (radians)

		float3 DirLightColor;     // Directional light color
		float DirLightAngle;      // Directional light angle relative to view (radians)
	};
	ConstantBuffer* farRainCB = nullptr;

	void ApplyFarRain();  // Post-process pass to apply far rain effect

	virtual inline std::string GetName() override { return "Rain"; }
	virtual inline std::string GetShortName() override { return "Rain"; }
	virtual inline std::string_view GetShaderDefineName() override { return "RAIN_FEATURE"; }
	virtual std::string_view GetCategory() const override { return "Weather"; }

	virtual std::pair<std::string, std::vector<std::string>> GetFeatureSummary() override
	{
		return {
			"Rain adds realistic light refraction and reflections through falling rain particles.\n"
			"Rain droplets refract the scene behind them and reflect the environment.",
			{ "Realistic rain particle refraction",
				"Environment reflections on raindrops",
				"Specular highlights from area lights",
				"Fresnel-based light response",
				"Enhanced rain visual fidelity" }
		};
	}

	virtual bool HasShaderDefine(RE::BSShader::Type shaderType) override;

	virtual void SetupResources() override;
	virtual void PostPostLoad() override;
	virtual void DrawSettings() override;
	virtual void LoadSettings(json& o_json) override;
	virtual void SaveSettings(json& o_json) override;
	virtual void RestoreDefaultSettings() override;

	void ClearRainBuffer();  // Clear rain normals buffer once per frame
	void ApplyRefraction();  // Post-process pass to apply refraction
	void DrawNormalsDebug();  // Debug: Draw rain normals to main render target

	virtual bool SupportsVR() override { return true; };

	struct BSParticleShader_SetupGeometry
	{
		static void thunk(RE::BSShader* shader, RE::BSRenderPass* pass, uint32_t flags);
		static inline REL::Relocation<decltype(thunk)> func;
	};
};
