#include <metal_stdlib>
#include <RealityKit/RealityKit.h>
using namespace metal;

inline float4 avatarRow(realitykit::surface_parameters p, uint index) {
    return float4(p.textures().custom().read(uint2(index, 0)));
}

template<bool Cutout, bool Outline>
inline void avatarShade(realitykit::surface_parameters p) {
    constexpr sampler sampleUV(coord::normalized, address::repeat, filter::linear);
    float2 uv = p.geometry().uv0();
    float4 base = avatarRow(p, 0);
    float4 flags = avatarRow(p, 8);
    float4 texel = flags.x > 0.5 ? float4(p.textures().base_color().sample(sampleUV, uv)) : float4(1.0);
    float alpha = base.a * texel.a;
    if (Cutout && alpha < float(p.material_constants().opacity_threshold())) { discard_fragment(); }
    float3 output;
    if (Outline) {
        output = avatarRow(p, 6).rgb;
    } else {
        float3 normal = normalize(p.geometry().normal());
        if (flags.w > 0.5) {
            float3 tangentNormal = float3(p.textures().normal().sample(sampleUV, uv).rgb) * 2.0 - 1.0;
            tangentNormal.xy *= avatarRow(p, 7).w;
            float3 t = p.geometry().tangent(), b = p.geometry().bitangent();
            if (dot(t, t) > 1e-6 && dot(b, b) > 1e-6) { normal = normalize(normalize(t) * tangentNormal.x + normalize(b) * tangentNormal.y + normal * tangentNormal.z); }
        }
        float4 shade = avatarRow(p, 1), light = avatarRow(p, 2), rim = avatarRow(p, 5);
        float amount = dot(normal, normalize(light.xyz)) + light.w;
        float transition = max(0.001, 1.0 - shade.w);
        float lit = smoothstep(-transition, transition, amount);
        float3 darkTexel = flags.y > 0.5 ? float3(p.textures().roughness().sample(sampleUV, uv).rgb) : texel.rgb;
        float3 surface = mix(shade.rgb * darkTexel, base.rgb * texel.rgb, lit);
        float3 ambient = avatarRow(p, 4).rgb;
        output = surface * (ambient + avatarRow(p, 3).rgb * lit);
        float grazing = saturate(1.0 - dot(normal, normalize(p.geometry().view_direction())) + avatarRow(p, 4).w);
        output += rim.rgb * pow(grazing, max(0.001, rim.w));
        float3 emission = avatarRow(p, 7).rgb;
        if (flags.z > 0.5) { emission *= float3(p.textures().emissive_color().sample(sampleUV, uv).rgb); }
        output += emission;
    }
    p.surface().set_base_color(half3(0.0));
    p.surface().set_emissive_color(half3(max(output, float3(0.0))));
    p.surface().set_opacity(half(avatarRow(p, 3).w > 0.5 ? alpha : 1.0));
}

[[visible]] void avatarToon(realitykit::surface_parameters p) { avatarShade<false, false>(p); }
[[visible]] void avatarToonMask(realitykit::surface_parameters p) { avatarShade<true, false>(p); }
[[visible]] void avatarOutline(realitykit::surface_parameters p) { avatarShade<false, true>(p); }
[[visible]] void avatarOutlineMask(realitykit::surface_parameters p) { avatarShade<true, true>(p); }

[[visible]] void avatarExpand(realitykit::geometry_parameters p) {
    float width = float(p.textures().custom().read(uint2(6, 0)).w);
    if (p.uniforms().custom_parameter().x > 0.5) {
        float4 view = p.uniforms().model_to_view() * float4(p.geometry().model_position(), 1.0);
        float projectionScale = max(1e-6, abs(p.uniforms().view_to_projection()[1][1]));
        width *= 2.0 * abs(view.z) / projectionScale;
    }
    float3 normal = normalize(p.uniforms().normal_to_world() * p.geometry().normal());
    float modelDistance = length((p.uniforms().world_to_model() * float4(normal, 0.0)).xyz);
    width = min(width, p.uniforms().custom_parameter().y / max(modelDistance, 1e-6));
    p.geometry().set_world_position_offset(normal * max(0.0, width));
}
