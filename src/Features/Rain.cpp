#include "Rain.h"

#include <DDSTextureLoader.h>

#include "Deferred.h"
#include "DynamicCubemaps.h"
#include "ShaderCache.h"
#include "State.h"

NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE_WITH_DEFAULT(
	Rain::Settings,
	EnableRain,
	RefractionStrength,
	RainWidth,
	RainLength,
	LightOpacity,
	FresnelPower,
	FresnelF0,
	IOR,
	ReflectionStrength,
	SpecularPower,
	SkyLightStrength,
	EnableFarRain,
	FarRainDistance,
	FarRainMaxDistance,
	FarRainSpeed)

void Rain::DrawSettings()
{
	ImGui::Checkbox("Enable Rain", (bool*)&settings.EnableRain);
	if (auto _tt = Util::HoverTooltipWrapper()) {
		ImGui::Text("Toggle rain effect on/off at runtime.");
	}

	ImGui::SeparatorText("Rain Appearance");

	ImGui::SliderFloat("Rain Width", &settings.RainWidth, 0.5f, 10.0f, "%.2f");
	if (auto _tt = Util::HoverTooltipWrapper()) {
		ImGui::Text("Controls how wide the rain particles appear. Higher values make rain streaks wider.");
	}

	ImGui::SliderFloat("Rain Length", &settings.RainLength, 0.1f, 5.0f, "%.2f");
	if (auto _tt = Util::HoverTooltipWrapper()) {
		ImGui::Text("Controls the length of rain streaks. Higher values make rain appear longer.");
	}

	ImGui::SeparatorText("Refraction");

	ImGui::SliderFloat("Refraction Strength", &settings.RefractionStrength, 0.0f, 2.0f, "%.2f");
	if (auto _tt = Util::HoverTooltipWrapper()) {
		ImGui::Text("Controls how much the scene is distorted through rain particles.");
	}

	ImGui::SliderFloat("Index of Refraction", &settings.IOR, 1.0f, 2.0f, "%.2f");
	if (auto _tt = Util::HoverTooltipWrapper()) {
		ImGui::Text("Index of refraction for water. Water = 1.33, glass = 1.5.");
	}

	ImGui::SeparatorText("Light");

	ImGui::SliderFloat("Light Opacity", &settings.LightOpacity, 0.0f, 2.0f, "%.2f");
	if (auto _tt = Util::HoverTooltipWrapper()) {
		ImGui::Text("How much light contribution is added.");
	}

	ImGui::SliderFloat("Environment Strength", &settings.SkyLightStrength, 0.0f, 2.0f, "%.2f");
	if (auto _tt = Util::HoverTooltipWrapper()) {
		ImGui::Text("Strength of environment cubemap reflections on rain.");
	}

	ImGui::SliderFloat("Reflection Strength", &settings.ReflectionStrength, 0.0f, 2.0f, "%.2f");
	if (auto _tt = Util::HoverTooltipWrapper()) {
		ImGui::Text("Multiplier for light reflection (light bouncing off droplet surface).");
	}

	ImGui::SliderFloat("Specular Power", &settings.SpecularPower, 0.0f, 25.0f, "%.1f");
	if (auto _tt = Util::HoverTooltipWrapper()) {
		ImGui::Text("Specular exponent for area light reflections. Higher = tighter highlights.");
	}

	ImGui::SeparatorText("Fresnel");

	ImGui::SliderFloat("Fresnel Power", &settings.FresnelPower, 1.0f, 10.0f, "%.1f");
	if (auto _tt = Util::HoverTooltipWrapper()) {
		ImGui::Text("Controls how sharply the fresnel falls off. Higher = more edge-focused effect.");
	}

	ImGui::SliderFloat("Fresnel F0", &settings.FresnelF0, 0.0f, 0.2f, "%.3f");
	if (auto _tt = Util::HoverTooltipWrapper()) {
		ImGui::Text("Base fresnel reflectance at normal incidence. Water is ~0.02-0.04.");
	}

	ImGui::SeparatorText("Far Rain");

	ImGui::Checkbox("Enable Far Rain", (bool*)&settings.EnableFarRain);
	if (auto _tt = Util::HoverTooltipWrapper()) {
		ImGui::Text("Adds distant rain streaks near the horizon.");
	}

	ImGui::SliderFloat("Far Rain Distance", &settings.FarRainDistance, 500.0f, 5000.0f, "%.0f");
	if (auto _tt = Util::HoverTooltipWrapper()) {
		ImGui::Text("Distance where far rain effect starts.");
	}

	ImGui::SliderFloat("Far Rain Max Distance", &settings.FarRainMaxDistance, 2000.0f, 20000.0f, "%.0f");
	if (auto _tt = Util::HoverTooltipWrapper()) {
		ImGui::Text("Distance where far rain effect reaches full strength.");
	}

	ImGui::SliderFloat("Far Rain Speed", &settings.FarRainSpeed, 0.5f, 10.0f, "%.1f");
	if (auto _tt = Util::HoverTooltipWrapper()) {
		ImGui::Text("Scroll speed of the rain streaks.");
	}
}

void Rain::LoadSettings(json& o_json)
{
	settings = o_json;
}

void Rain::SaveSettings(json& o_json)
{
	o_json = settings;
}

void Rain::RestoreDefaultSettings()
{
	settings = {};
}

bool Rain::HasShaderDefine(RE::BSShader::Type shaderType)
{
	return shaderType == RE::BSShader::Type::Particle;
}

void Rain::SetupResources()
{
	auto renderer = globals::game::renderer;
	auto& main = renderer->GetRuntimeData().renderTargets[RE::RENDER_TARGETS::kMAIN];

	D3D11_TEXTURE2D_DESC texDesc{};
	main.texture->GetDesc(&texDesc);

	// Create rain normals buffer (RGBA16F format for normal data)
	texDesc.Format = DXGI_FORMAT_R16G16B16A16_FLOAT;
	texDesc.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;

	rainNormalsBuffer = new Texture2D(texDesc);
	rainNormalsBuffer->CreateSRV(CD3D11_SHADER_RESOURCE_VIEW_DESC(
		rainNormalsBuffer->resource.get(), D3D11_SRV_DIMENSION_TEXTURE2D, texDesc.Format));
	rainNormalsBuffer->CreateRTV(CD3D11_RENDER_TARGET_VIEW_DESC(
		rainNormalsBuffer->resource.get(), D3D11_RTV_DIMENSION_TEXTURE2D, texDesc.Format));

	// Create rain light buffer (RGB = accumulated light color, A = unused)
	rainLightBuffer = new Texture2D(texDesc);
	rainLightBuffer->CreateSRV(CD3D11_SHADER_RESOURCE_VIEW_DESC(
		rainLightBuffer->resource.get(), D3D11_SRV_DIMENSION_TEXTURE2D, texDesc.Format));
	rainLightBuffer->CreateRTV(CD3D11_RENDER_TARGET_VIEW_DESC(
		rainLightBuffer->resource.get(), D3D11_RTV_DIMENSION_TEXTURE2D, texDesc.Format));

	// Load rain normals texture
	auto device = globals::d3d::device;
	ID3D11Resource* resource = nullptr;
	ID3D11ShaderResourceView* srv = nullptr;

	if (SUCCEEDED(DirectX::CreateDDSTextureFromFile(device, L"Data\\Shaders\\Rain\\rain_normals.dds", &resource, &srv))) {
		rainNormalsTexture = new Texture2D(reinterpret_cast<ID3D11Texture2D*>(resource));
		rainNormalsTexture->srv.attach(srv);
		logger::info("[Rain] Rain normals texture loaded successfully");
	} else {
		logger::warn("[Rain] Failed to load rain normals texture, will use procedural normals");
	}

	// Create constant buffer for refraction pass
	refractionCB = new ConstantBuffer(ConstantBufferDesc<RefractionCB>());

	// Create constant buffer for far rain pass
	farRainCB = new ConstantBuffer(ConstantBufferDesc<FarRainCB>());

	// Create wrap sampler for far rain (bilinear + wrap for seamless tiling)
	D3D11_SAMPLER_DESC samplerDesc = {};
	samplerDesc.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
	samplerDesc.AddressU = D3D11_TEXTURE_ADDRESS_WRAP;
	samplerDesc.AddressV = D3D11_TEXTURE_ADDRESS_WRAP;
	samplerDesc.AddressW = D3D11_TEXTURE_ADDRESS_WRAP;
	samplerDesc.MaxAnisotropy = 1;
	samplerDesc.MinLOD = 0;
	samplerDesc.MaxLOD = D3D11_FLOAT32_MAX;
	device->CreateSamplerState(&samplerDesc, &wrapSampler);

	// Load blue noise texture for far rain (reuse Skylighting's texture)
	if (SUCCEEDED(DirectX::CreateDDSTextureFromFile(device, globals::d3d::context,
			L"Data\\Shaders\\Skylighting\\SpatiotemporalBlueNoise\\stbn_vec3_2Dx1D_128x128x64.dds",
			nullptr, &blueNoiseSRV))) {
		logger::info("[Rain] Blue noise texture loaded successfully");
	} else {
		logger::warn("[Rain] Failed to load blue noise texture, far rain may not work");
	}

	logger::info("[Rain] Resources setup complete");
}

ID3D11ComputeShader* Rain::GetComputeShaderRefraction()
{
	if (!refractionCS) {
		refractionCS = (ID3D11ComputeShader*)Util::CompileShader(L"Data\\Shaders\\Rain\\RefractionCS.hlsl", {}, "cs_5_0");
	}
	return refractionCS;
}

ID3D11ComputeShader* Rain::GetComputeShaderFarRain()
{
	if (!farRainCS) {
		farRainCS = (ID3D11ComputeShader*)Util::CompileShader(L"Data\\Shaders\\Rain\\FarRainCS.hlsl", {}, "cs_5_0");
	}
	return farRainCS;
}

void Rain::PostPostLoad()
{
	logger::info("[Rain] Hooking BSParticleShader::SetupGeometry");
	stl::write_vfunc<0x6, BSParticleShader_SetupGeometry>(RE::VTABLE_BSParticleShader[0]);
	logger::info("[Rain] Hook installed successfully");
}

void Rain::ClearRainBuffer()
{
	auto context = globals::d3d::context;
	float clearColor[4] = { 0.5f, 0.5f, 0.0f, 0.0f };  // 0.5 = no refraction offset
	context->ClearRenderTargetView(rainNormalsBuffer->rtv.get(), clearColor);

	float lightClearColor[4] = { 0.0f, 0.0f, 0.0f, 0.0f };  // No light contribution
	context->ClearRenderTargetView(rainLightBuffer->rtv.get(), lightClearColor);
}

void Rain::ParticleShaderHacks()
{
	if (overrideParticle) {
		auto context = globals::d3d::context;
		auto renderer = globals::game::renderer;

		// Only set up MRT for rain particles
		if (isRainParticle) {
			// Get current render targets
			ID3D11DepthStencilView* dsv = nullptr;
			ID3D11RenderTargetView* originalRtvs[8] = { nullptr };
			context->OMGetRenderTargets(8, originalRtvs, &dsv);

			// Count how many RTs are currently bound
			uint32_t numBoundRTs = 0;
			for (uint32_t i = 0; i < 8; i++) {
				if (originalRtvs[i] != nullptr) {
					numBoundRTs = i + 1;
				} else {
					break;
				}
			}

			// Create modified RT array with rain normals at slot 3
			ID3D11RenderTargetView* modifiedRtvs[8] = { nullptr };
			for (uint32_t i = 0; i < 8; i++) {
				modifiedRtvs[i] = originalRtvs[i];
			}

			// Fill gaps to reach slot 4 if needed
			uint32_t slotsNeeded = 5;
			if (numBoundRTs < slotsNeeded && originalRtvs[0] != nullptr) {
				for (uint32_t i = numBoundRTs; i < slotsNeeded - 2; i++) {
					modifiedRtvs[i] = originalRtvs[0];
				}
			}

			// Bind rain normals buffer at slot 3, light buffer at slot 4
			modifiedRtvs[3] = rainNormalsBuffer->rtv.get();
			modifiedRtvs[4] = rainLightBuffer->rtv.get();

			// Bind modified RT array
			context->OMSetRenderTargets(5, modifiedRtvs, dsv);

			// Get precipitation occlusion depth texture (t2) - required for depth culling
			auto& precipitationOcclusion = renderer->GetDepthStencilData()
				.depthStencils[RE::RENDER_TARGETS_DEPTHSTENCIL::kPRECIPITATION_OCCLUSION_MAP];

			// Get underwater mask texture (t3) - required for underwater culling
			auto& underwaterMask = renderer->GetRuntimeData()
				.renderTargets[RE::RENDER_TARGET::kUNDERWATER_MASK];

			// Bind textures required for depth testing (ENVCUBE particles need these)
			ID3D11ShaderResourceView* depthTextures[2] = {
				precipitationOcclusion.depthSRV,  // t2
				underwaterMask.SRV                 // t3
			};
			context->PSSetShaderResources(2, 2, depthTextures);

			// Bind rain normals texture as input (t65)
			ID3D11ShaderResourceView* srv = rainNormalsTexture ? rainNormalsTexture->srv.get() : nullptr;
			context->PSSetShaderResources(65, 1, &srv);

			// Release COM objects to prevent memory leaks
			if (dsv)
				dsv->Release();
			for (int i = 0; i < 8; i++) {
				if (originalRtvs[i])
					originalRtvs[i]->Release();
			}

			isRainParticle = false;
		}

		overrideParticle = false;
	}
}

void Rain::BSParticleShader_SetupGeometry::thunk(RE::BSShader* shader, RE::BSRenderPass* pass, uint32_t flags)
{
	auto& rain = globals::features::rain;
	if (!rain.loaded || !rain.settings.EnableRain) {
		func(shader, pass, flags);
		return;
	}

	// Set flag for ALL particles to bind the rain normals buffer as MRT
	rain.overrideParticle = true;

	// Check if this is specifically a rain particle for additional setup
	auto particleProperty = netimmerse_cast<RE::BSParticleShaderProperty*>(pass->shaderProperty);
	if (particleProperty && particleProperty->particleEmitter) {
		auto emitter = particleProperty->particleEmitter;
		if (emitter->emitterType.any(RE::BSParticleShaderEmitter::EMITTER_TYPE::kRain)) {
			rain.isRainParticle = true;
		}
	}

	func(shader, pass, flags);
}

void Rain::DrawNormalsDebug()
{
	auto context = globals::d3d::context;
	auto renderer = globals::game::renderer;
	auto& main = renderer->GetRuntimeData().renderTargets[RE::RENDER_TARGETS::kMAIN];

	// Copy the rain normals buffer to the main render target using CopyResource
	// This will show the raw normal data (RGB = normal XYZ, A = strength)
	context->CopyResource(main.texture, rainNormalsBuffer->resource.get());

	// Clear the buffer for the next frame
	ClearRainBuffer();
}

void Rain::ApplyRefraction()
{
	auto context = globals::d3d::context;
	auto renderer = globals::game::renderer;
	auto& main = renderer->GetRuntimeData().renderTargets[RE::RENDER_TARGETS::kMAIN];

	// Create temporary texture to hold copy of main render target (once)
	if (!mainCopy) {
		D3D11_TEXTURE2D_DESC texDesc{};
		main.texture->GetDesc(&texDesc);
		texDesc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
		mainCopy = new Texture2D(texDesc);
		mainCopy->CreateSRV(CD3D11_SHADER_RESOURCE_VIEW_DESC(
			mainCopy->resource.get(), D3D11_SRV_DIMENSION_TEXTURE2D, texDesc.Format));
	}

	// Copy main buffer so we can sample from it
	context->CopyResource(mainCopy->resource.get(), main.texture);

	// Update constant buffer with multiplied values
	RefractionCB cbData;
	cbData.RefractionStrength = settings.RefractionStrength;
	cbData.LightOpacity = settings.LightOpacity * 2.0f;  // Multiply by 2 for internal use
	cbData.IOR = settings.IOR;
	cbData.pad = 0.0f;
	refractionCB->Update(cbData);

	// Bind UAV for output (write to kMAIN)
	ID3D11UnorderedAccessView* uav = main.UAV;
	context->CSSetUnorderedAccessViews(0, 1, &uav, nullptr);

	// Bind SRVs for input (t0 = mainCopy, t1 = rainNormals, t2 = rainLight, t3 = envReflections)
	auto& dynamicCubemaps = globals::features::dynamicCubemaps;
	ID3D11ShaderResourceView* envSRV = dynamicCubemaps.loaded ? dynamicCubemaps.envReflectionsTexture->srv.get() : nullptr;
	ID3D11ShaderResourceView* srvs[4] = { mainCopy->srv.get(), rainNormalsBuffer->srv.get(), rainLightBuffer->srv.get(), envSRV };
	context->CSSetShaderResources(0, 4, srvs);

	// Bind sampler for env cube
	ID3D11SamplerState* sampler = Deferred::GetSingleton()->linearSampler;
	context->CSSetSamplers(0, 1, &sampler);

	// Bind constant buffer
	ID3D11Buffer* cbs[1] = { refractionCB->CB() };
	context->CSSetConstantBuffers(1, 1, cbs);

	// Get dispatch count
	auto dispatchCount = Util::GetScreenDispatchCount();

	// Run compute shader
	auto shader = GetComputeShaderRefraction();
	context->CSSetShader(shader, nullptr, 0);
	context->Dispatch(dispatchCount.x, dispatchCount.y, 1);

	// Unbind resources
	ID3D11UnorderedAccessView* nullUAV = nullptr;
	context->CSSetUnorderedAccessViews(0, 1, &nullUAV, nullptr);

	ID3D11ShaderResourceView* nullSRVs[4] = { nullptr, nullptr, nullptr, nullptr };
	context->CSSetShaderResources(0, 4, nullSRVs);

	ID3D11SamplerState* nullSampler = nullptr;
	context->CSSetSamplers(0, 1, &nullSampler);

	ID3D11Buffer* nullCB = nullptr;
	context->CSSetConstantBuffers(1, 1, &nullCB);

	context->CSSetShader(nullptr, nullptr, 0);

	// Clear the rain normals buffer for the next frame
	ClearRainBuffer();
}

void Rain::ApplyFarRain()
{
	if (!settings.EnableFarRain || !blueNoiseSRV)
		return;

	auto context = globals::d3d::context;
	auto renderer = globals::game::renderer;
	auto& main = renderer->GetRuntimeData().renderTargets[RE::RENDER_TARGETS::kMAIN];
	// Use POST_ZPREPASS_COPY which is a reliable copy of the depth buffer
	auto& depth = renderer->GetDepthStencilData().depthStencils[RE::RENDER_TARGETS_DEPTHSTENCIL::kPOST_ZPREPASS_COPY];

	// Get screen dimensions
	D3D11_TEXTURE2D_DESC texDesc{};
	main.texture->GetDesc(&texDesc);

	// Get time from State
	float time = State::GetSingleton()->timer;

	// Get wind direction and strength in world space
	float windAngleWorld = 0.0f;
	float windTilt = 0.05f;  // Default small tilt
	float rainIntensity = 1.0f;

	if (auto sky = globals::game::sky) {
		if (auto weather = sky->currentWeather) {
			// Get effective wind direction in world space (same calculation as WeatherPicker)
			// Flip direction (+180 degrees) so rain falls in the wind direction
			float windDegrees = Util::Units::DirectionRawToDegrees(weather->data.windDirection) - 30.5f + 180.0f;  // WIND_DIRECTION_OFFSET + flip
			windAngleWorld = windDegrees * 0.0174533f;  // degrees to radians

			// Wind strength determines tilt angle (0.2 * 20 = 4 base multiplier)
			float windStrength = sky->windSpeed * 4.0f;
			windTilt = windStrength * 0.26f;  // max ~15 degrees at full wind
		}

		// Rain intensity from weather particle density
		if (auto weather = sky->currentWeather) {
			if (weather->precipitationData) {
				auto maxDensity = weather->precipitationData->GetSettingValue(RE::BGSShaderParticleGeometryData::DataID::kParticleDensity).f;
				rainIntensity = maxDensity / 3.0f;  // Normalize to 0-1 range (max density is ~3)
			}
		}
	}

	// Get directional light info from sun
	float3 dirLightColor = { 0.7f, 0.75f, 0.85f };  // Default grey-blue
	float dirLightAngleRelative = 0.0f;
	if (auto shaderManager = globals::game::smState) {
		auto shadowSceneNode = shaderManager->shadowSceneNode[0];
		if (shadowSceneNode && shadowSceneNode->GetRuntimeData().sunLight) {
			auto dirLight = skyrim_cast<RE::NiDirectionalLight*>(shadowSceneNode->GetRuntimeData().sunLight->light.get());
			if (dirLight) {
				auto& lightRuntimeData = dirLight->GetLightRuntimeData();
				dirLightColor = { lightRuntimeData.diffuse.red, lightRuntimeData.diffuse.green, lightRuntimeData.diffuse.blue };
				// Normalize and ensure minimum brightness for rain tint
				float maxC = std::max({ dirLightColor.x, dirLightColor.y, dirLightColor.z, 0.1f });
				dirLightColor.x = dirLightColor.x / maxC * 0.5f + 0.5f;
				dirLightColor.y = dirLightColor.y / maxC * 0.5f + 0.5f;
				dirLightColor.z = dirLightColor.z / maxC * 0.5f + 0.5f;
			}
		}
	}

	// Update constant buffer with hardcoded values
	FarRainCB cbData;
	cbData.FarRainDistance = settings.FarRainDistance;
	cbData.FarRainMaxDistance = settings.FarRainMaxDistance;
	cbData.FarRainOpacity = 0.4f * rainIntensity;  // Base opacity 0.4, scaled by rain intensity
	cbData.FarRainSpeed = settings.FarRainSpeed;
	cbData.FarRainStretch = 8.0f;           // Hardcoded
	cbData.FarRainScale = 2.0f;             // Hardcoded (larger scale = bigger rain pattern)
	cbData.FarRainHorizonAngle = 1.309f;    // 75 degrees in radians
	cbData.Time = time;
	cbData.BufferDimX = (float)texDesc.Width;
	cbData.BufferDimY = (float)texDesc.Height;
	cbData.WindAngleRelative = windAngleWorld;  // World space wind direction
	cbData.WindTilt = windTilt;
	cbData.DirLightColor = dirLightColor;
	cbData.DirLightAngle = dirLightAngleRelative;
	farRainCB->Update(cbData);

	// Bind UAV for output (write to kMAIN)
	ID3D11UnorderedAccessView* uav = main.UAV;
	context->CSSetUnorderedAccessViews(0, 1, &uav, nullptr);

	// Bind SRVs for input (t0 = depth, t1 = blue noise)
	ID3D11ShaderResourceView* srvs[2] = { depth.depthSRV, blueNoiseSRV };
	context->CSSetShaderResources(0, 2, srvs);

	// Bind constant buffer (b1 = farRainCB)
	ID3D11Buffer* cbs[1] = { farRainCB->CB() };
	context->CSSetConstantBuffers(1, 1, cbs);

	// Bind game's FrameBuffer (b12) and perFrame buffer for SharedData/FrameBuffer access
	{
		ID3D11Buffer* frameBuffers[1] = { *globals::game::perFrame };
		context->CSSetConstantBuffers(12, 1, frameBuffers);
	}

	// Bind wrap sampler for bilinear filtering with seamless tiling
	context->CSSetSamplers(0, 1, &wrapSampler);

	// Get dispatch count
	auto dispatchCount = Util::GetScreenDispatchCount();

	// Run compute shader
	auto shader = GetComputeShaderFarRain();
	if (!shader)
		return;

	context->CSSetShader(shader, nullptr, 0);
	context->Dispatch(dispatchCount.x, dispatchCount.y, 1);

	// Unbind resources
	ID3D11UnorderedAccessView* nullUAV = nullptr;
	context->CSSetUnorderedAccessViews(0, 1, &nullUAV, nullptr);

	ID3D11ShaderResourceView* nullSRVs[2] = { nullptr, nullptr };
	context->CSSetShaderResources(0, 2, nullSRVs);

	ID3D11Buffer* nullCB = nullptr;
	context->CSSetConstantBuffers(1, 1, &nullCB);

	ID3D11SamplerState* nullSampler = nullptr;
	context->CSSetSamplers(0, 1, &nullSampler);

	context->CSSetShader(nullptr, nullptr, 0);
}
