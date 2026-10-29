#include <metal_stdlib>
#include <RealityKit/RealityKit.h>
using namespace metal;

// Shared with MaterialLayout in TextureAtlas.swift. Parameters and UV scalars use byte
// encoding so RealityKit's half texture access cannot round a row index or a UV value.
constant uint avatarMaterialStride = 128;
constant uint avatarTextureStart = 12;
constant uint avatarTextureStride = 9;
constant uint avatarLightStart = 12;
constant uint avatarLightStride = 8;
constant uint avatarShadowStride = 19;
constant uint avatarScalarStart = 111;

inline uint avatarInteger(float4 value) {
    uint4 bytes = uint4(round(value));
    return bytes.x | (bytes.y << 8) | (bytes.z << 16) | (bytes.w << 24);
}
inline uint2 avatarPair(float4 value) {
    uint4 bytes = uint4(round(value));
    return uint2(bytes.x | (bytes.y << 8), bytes.z | (bytes.w << 8));
}
inline float avatarFloat(float4 value) { return as_type<float>(avatarInteger(value)); }

template<typename Texture>
inline float4 avatarRow(Texture texture, uint row) {
    uint width = texture.get_width();
    return float4(texture.read(uint2(row % width, row / width)));
}

template<typename Texture>
inline float2 avatarUV(Texture images, uint table, uint triangle, float2 barycentric, uint set) {
    uint2 header = uint2(avatarRow(images, table).xy);
    if (set >= header.x) { return float2(0.0); }
    uint row = table + 1 + triangle * header.y + set * 6;
    float2 a(avatarFloat(avatarRow(images, row)), avatarFloat(avatarRow(images, row + 1)));
    float2 b(avatarFloat(avatarRow(images, row + 2)), avatarFloat(avatarRow(images, row + 3)));
    float2 c(avatarFloat(avatarRow(images, row + 4)), avatarFloat(avatarRow(images, row + 5)));
    return a * (1.0 - barycentric.x - barycentric.y) + b * barycentric.x + c * barycentric.y;
}

inline int avatarPixel(int pixel, int size, uint mode) {
    if (mode == 0) { return clamp(pixel, 0, size - 1); }
    int period = mode == 2 ? size * 2 : size;
    int wrapped = ((pixel % period) + period) % period;
    return mode == 2 && wrapped >= size ? period - 1 - wrapped : wrapped;
}
inline float avatarCoordinate(float value, uint mode) {
    if (mode == 0) { return clamp(value, 0.0, 1.0); }
    if (mode == 1) { return fract(value); }
    float phase = value - floor(value * 0.5) * 2.0;
    return phase;
}

template<typename Texture>
inline float4 avatarLevel(Texture images, uint descriptor, uint level, float2 uv, uint2 wrap, bool linear) {
    uint2 origin = avatarPair(avatarRow(images, descriptor + level * 2));
    uint2 size = avatarPair(avatarRow(images, descriptor + level * 2 + 1));
    uv = float2(avatarCoordinate(uv.x, wrap.x), avatarCoordinate(uv.y, wrap.y));
    if (!linear) {
        int2 p = int2(floor(uv * float2(size)));
        uint2 pixel(avatarPixel(p.x, size.x, wrap.x), avatarPixel(p.y, size.y, wrap.y));
        return float4(images.read(origin + pixel));
    }
    float2 p = uv * float2(size) - 0.5;
    int2 lower = int2(floor(p));
    float2 amount = fract(p);
    uint2 p00(avatarPixel(lower.x, size.x, wrap.x), avatarPixel(lower.y, size.y, wrap.y));
    uint2 p10(avatarPixel(lower.x + 1, size.x, wrap.x), p00.y);
    uint2 p01(p00.x, avatarPixel(lower.y + 1, size.y, wrap.y));
    uint2 p11(p10.x, p01.y);
    return mix(mix(float4(images.read(origin + p00)), float4(images.read(origin + p10)), amount.x),
               mix(float4(images.read(origin + p01)), float4(images.read(origin + p11)), amount.x), amount.y);
}

template<typename Images, typename Parameters>
inline float4 avatarTexture(Images images, Parameters parameters, uint slot, float2 uv, float2 dx, float2 dy, float4 fallback) {
    float4 info = avatarRow(parameters, slot + 1);
    if (info.x < 0.5) { return fallback; }
    uint descriptor = avatarInteger(avatarRow(parameters, slot));
    float2 size = float2(avatarPair(avatarRow(images, descriptor + 1)));
    float footprint = max(length(dx * size), length(dy * size));
    float lod = log2(max(footprint, 1e-8));
    uint2 wrap = uint2(info.zw);
    float4 filter = avatarRow(parameters, slot + 2);
    if (lod <= 0.0) { return avatarLevel(images, descriptor, 0, uv, wrap, filter.y > 0.5); }
    uint minFilter = uint(filter.x);
    if (minFilter < 2) { return avatarLevel(images, descriptor, 0, uv, wrap, minFilter == 1); }
    lod = clamp(lod, 0.0, info.x - 1.0);
    bool linear = (minFilter & 1u) != 0;
    if (minFilter < 4) { return avatarLevel(images, descriptor, uint(round(lod)), uv, wrap, linear); }
    uint low = uint(floor(lod)), high = min(low + 1, uint(info.x - 1));
    return mix(avatarLevel(images, descriptor, low, uv, wrap, linear), avatarLevel(images, descriptor, high, uv, wrap, linear), fract(lod));
}

template<typename Parameters>
inline float2 avatarTransform(Parameters parameters, uint slot, float2 uv) {
    float2 scale(avatarFloat(avatarRow(parameters, slot + 3)), avatarFloat(avatarRow(parameters, slot + 4)));
    float2 offset(avatarFloat(avatarRow(parameters, slot + 5)), avatarFloat(avatarRow(parameters, slot + 6)));
    float angle = avatarFloat(avatarRow(parameters, slot + 7));
    float c = cos(angle), s = sin(angle);
    uv *= scale;
    return float2(c * uv.x - s * uv.y, s * uv.x + c * uv.y) + offset;
}

template<typename Parameters>
inline float2 avatarAnimation(Parameters parameters, uint material, float2 uv, float time, float mask) {
    float2 scroll(avatarFloat(avatarRow(parameters, material + avatarScalarStart + 8)), avatarFloat(avatarRow(parameters, material + avatarScalarStart + 9)));
    float speed = avatarFloat(avatarRow(parameters, material + avatarScalarStart + 10));
    float angle = fmod(speed * time * mask, 2.0 * M_PI_F), c = cos(angle), s = sin(angle);
    float2 centered = uv - 0.5;
    return float2(c * centered.x - s * centered.y, s * centered.x + c * centered.y) + 0.5 + scroll * time * mask;
}

template<typename Images, typename Parameters>
inline float2 avatarSlotUV(Images images, Parameters parameters, uint material, uint table, uint triangle,
                          float2 barycentric, uint use, float time, float mask, bool animated) {
    uint slot = material + avatarTextureStart + use * avatarTextureStride;
    uint set = uint(avatarRow(parameters, slot + 1).y);
    float2 uv = avatarUV(images, table, triangle, barycentric, set);
    if (animated) { uv = avatarAnimation(parameters, material, uv, time, mask); }
    return avatarTransform(parameters, slot, uv);
}

template<typename Texture>
inline float3 avatarGI(Texture parameters, uint global, float3 n) {
    float basis[9] = {0.282095, 0.488603 * n.y, 0.488603 * n.z, 0.488603 * n.x,
                     1.092548 * n.x * n.y, 1.092548 * n.y * n.z, 0.315392 * (3.0 * n.z * n.z - 1.0),
                     1.092548 * n.x * n.z, 0.546274 * (n.x * n.x - n.y * n.y)};
    float3 color(0.0);
    for (uint i = 0; i < 9; ++i) { color += avatarRow(parameters, global + 1 + i).rgb * basis[i]; }
    return max(color, float3(0.0));
}

template<typename Texture>
inline float4x4 avatarShadowMatrix(Texture parameters, uint row) {
    float4x4 matrix;
    for (uint column = 0; column < 4; ++column) {
        for (uint lane = 0; lane < 4; ++lane) { matrix[column][lane] = avatarFloat(avatarRow(parameters, row + 3 + column * 4 + lane)); }
    }
    return matrix;
}

template<typename Texture>
inline float avatarShadow(Texture parameters, uint light, float3 position, float3 normal) {
    float4 settings = avatarRow(parameters, light + 5);
    if (settings.w < 0.5) { return 1.0; }
    uint row = avatarInteger(avatarRow(parameters, light + 6));
    if (settings.w > 1.5) {
        float3 lightPosition(avatarFloat(avatarRow(parameters, light + 1)), avatarFloat(avatarRow(parameters, light + 2)), avatarFloat(avatarRow(parameters, light + 3)));
        float3 d = position - lightPosition, a = abs(d);
        uint face = a.x >= a.y && a.x >= a.z ? (d.x >= 0 ? 0 : 1) : a.y >= a.z ? (d.y >= 0 ? 2 : 3) : (d.z >= 0 ? 4 : 5);
        row += face * avatarShadowStride;
    }
    float4 bias = avatarRow(parameters, row + 2);
    float4 projected = avatarShadowMatrix(parameters, row) * float4(position + normal * bias.y, 1.0);
    if (projected.w <= 0.0) { return 1.0; }
    float3 ndc = projected.xyz / projected.w;
    float2 uv = float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
    if (any(uv < 0.0) || any(uv > 1.0) || ndc.z < 0.0 || ndc.z > 1.0) { return 1.0; }
    uint2 origin = avatarPair(avatarRow(parameters, row)), size = avatarPair(avatarRow(parameters, row + 1));
    int2 center = int2(uv * float2(size));
    float visibility = 0.0;
    for (int y = -1; y <= 1; ++y) { for (int x = -1; x <= 1; ++x) {
        uint2 p = uint2(clamp(center + int2(x, y), int2(0), int2(size) - 1));
        float2 stored = float2(parameters.read(origin + p).rg);
        visibility += ndc.z - bias.x <= stored.x + stored.y ? 1.0 : 0.0;
    } }
    return mix(1.0, visibility / 9.0, bias.z);
}

template<typename Texture>
inline float3 avatarLight(Texture parameters, uint row, float3 position, thread float3 &direction) {
    float4 color = avatarRow(parameters, row);
    float3 ray = normalize(avatarRow(parameters, row + 4).xyz);
    if (color.w < 0.5) { direction = -ray; return color.rgb; }
    float3 point(avatarFloat(avatarRow(parameters, row + 1)), avatarFloat(avatarRow(parameters, row + 2)), avatarFloat(avatarRow(parameters, row + 3)));
    float3 delta = point - position;
    float distance = length(delta);
    direction = distance > 1e-6 ? delta / distance : -ray;
    float4 settings = avatarRow(parameters, row + 5);
    float range = max(avatarFloat(avatarRow(parameters, row + 7)), 1e-6);
    float fade = saturate(1.0 - pow(distance / range, 4.0));
    float attenuation = fade * fade / pow(max(distance, 0.01), max(settings.z, 0.0));
    if (color.w > 1.5) {
        float inner = avatarRow(parameters, row + 4).w, outer = settings.x, angle = dot(-direction, ray);
        float cone = inner > outer + 1e-6 ? saturate((angle - outer) / (inner - outer)) : step(outer, angle);
        attenuation *= cone * cone;
    }
    return color.rgb * attenuation;
}

struct AvatarSurface {
    float3 color;
    float alpha;
};

template<typename Images, typename Parameters>
inline AvatarSurface avatarMToon(Images images, Parameters parameters, uint material, uint table, uint triangle,
                                 float2 barycentric, float time, float3 position, float3 geometricNormal,
                                 float3 view, float3 tangent, float3 bitangent) {
    uint maskSlot = material + avatarTextureStart + 8 * avatarTextureStride;
    float2 maskUV = avatarSlotUV(images, parameters, material, table, triangle, barycentric, 8, time, 1.0, false);
    float mask = avatarTexture(images, parameters, maskSlot, maskUV, dfdx(maskUV), dfdy(maskUV), float4(1.0)).b;
    float2 uv[9];
    for (uint use = 0; use < 9; ++use) { uv[use] = avatarSlotUV(images, parameters, material, table, triangle, barycentric, use, time, mask, use != 5 && use != 8); }
    float4 base = avatarRow(parameters, material);
    float4 sampleBase = avatarTexture(images, parameters, material + avatarTextureStart, uv[0], dfdx(uv[0]), dfdy(uv[0]), float4(1.0));
    float3 litColor = base.rgb * sampleBase.rgb;
    float alpha = base.a * sampleBase.a;
    float3 normal = normalize(geometricNormal);
    uint normalSlot = material + avatarTextureStart + avatarTextureStride;
    if (avatarRow(parameters, normalSlot + 1).x > 0.5) {
        float3 mapped = avatarTexture(images, parameters, normalSlot, uv[1], dfdx(uv[1]), dfdy(uv[1]), float4(0.5, 0.5, 1.0, 1.0)).xyz * 2.0 - 1.0;
        mapped.xy *= avatarFloat(avatarRow(parameters, material + avatarScalarStart + 11));
        mapped = normalize(mapped);
        if (dot(tangent, tangent) < 1e-8 || dot(bitangent, bitangent) < 1e-8) {
            uint set = uint(avatarRow(parameters, normalSlot + 1).y);
            float2 original = avatarUV(images, table, triangle, barycentric, set);
            float2 tx = dfdx(original), ty = dfdy(original);
            float3 px = dfdx(position), py = dfdy(position);
            float determinant = tx.x * ty.y - tx.y * ty.x;
            if (abs(determinant) > 1e-8) {
                tangent = (px * ty.y - py * tx.y) / determinant;
                bitangent = (py * tx.x - px * ty.x) / determinant;
            }
        }
        if (dot(tangent, tangent) > 1e-8 && dot(bitangent, bitangent) > 1e-8) {
            tangent = normalize(tangent - normal * dot(normal, tangent));
            float handedness = dot(cross(normal, tangent), bitangent) < 0.0 ? -1.0 : 1.0;
            bitangent = normalize(cross(normal, tangent)) * handedness;
            normal = normalize(tangent * mapped.x + bitangent * mapped.y + normal * mapped.z);
        }
    }
    if (avatarRow(parameters, material + 8).w > 0.5 && dot(geometricNormal, view) < 0.0) { normal = -normal; }
    float3 shade = avatarRow(parameters, material + 1).rgb;
    shade *= avatarTexture(images, parameters, material + avatarTextureStart + 3 * avatarTextureStride, uv[3], dfdx(uv[3]), dfdy(uv[3]), float4(1.0)).rgb;
    uint shiftSlot = material + avatarTextureStart + 4 * avatarTextureStride;
    float shift = avatarFloat(avatarRow(parameters, material + avatarScalarStart + 2));
    shift += avatarTexture(images, parameters, shiftSlot, uv[4], dfdx(uv[4]), dfdy(uv[4]), float4(0.0)).r * avatarFloat(avatarRow(parameters, shiftSlot + 8));
    float toony = avatarFloat(avatarRow(parameters, material + avatarScalarStart));
    uint global = avatarInteger(avatarRow(parameters, material + 11));
    float equalization = avatarFloat(avatarRow(parameters, material + avatarScalarStart + 1));
    float3 uniformGI = (avatarGI(parameters, global, float3(0, 1, 0)) + avatarGI(parameters, global, float3(0, -1, 0))) * 0.5;
    float3 gi = mix(avatarGI(parameters, global, normal), uniformGI, equalization);
    float3 output = gi * litColor, lighting = gi;
    uint lightCount = min(64u, uint(avatarRow(parameters, global).x));
    for (uint index = 0; index < lightCount; ++index) {
        uint row = global + avatarLightStart + index * avatarLightStride;
        float3 direction;
        float3 light = avatarLight(parameters, row, position, direction);
        light *= avatarShadow(parameters, row, position, normal);
        float value = dot(normal, direction) + shift;
        float width = 1.0 - toony;
        float shading = width <= 1e-6 ? step(0.0, value) : saturate((value + width) / (2.0 * width));
        output += mix(shade, litColor, shading) * light;
        lighting += light;
    }
    float3 viewX = float3(view.z, 0.0, -view.x);
    viewX = dot(viewX, viewX) > 1e-8 ? normalize(viewX) : float3(1, 0, 0);
    float3 viewY = normalize(cross(view, viewX));
    float2 matcapUV = float2(dot(viewX, normal), dot(viewY, normal)) * 0.495 + 0.5;
    matcapUV.y = 1.0 - matcapUV.y;
    uint matcapSlot = material + avatarTextureStart + 5 * avatarTextureStride;
    matcapUV = avatarTransform(parameters, matcapSlot, matcapUV);
    float3 rim = avatarRow(parameters, material + 4).rgb * avatarTexture(images, parameters, matcapSlot, matcapUV, dfdx(matcapUV), dfdy(matcapUV), float4(0.0)).rgb;
    float power = max(1e-5, avatarFloat(avatarRow(parameters, material + avatarScalarStart + 3)));
    float lift = avatarFloat(avatarRow(parameters, material + avatarScalarStart + 4));
    rim += avatarRow(parameters, material + 3).rgb * pow(saturate(1.0 - dot(normal, view) + lift), power);
    rim *= avatarTexture(images, parameters, material + avatarTextureStart + 6 * avatarTextureStride, uv[6], dfdx(uv[6]), dfdy(uv[6]), float4(1.0)).rgb;
    rim *= mix(float3(1.0), lighting, avatarFloat(avatarRow(parameters, material + avatarScalarStart + 5)));
    output += rim;
    output += avatarRow(parameters, material + 2).rgb * avatarTexture(images, parameters, material + avatarTextureStart + 2 * avatarTextureStride, uv[2], dfdx(uv[2]), dfdy(uv[2]), float4(1.0)).rgb;
    return {max(output, float3(0.0)), alpha};
}

template<bool Cutout, bool Outline>
inline void avatarShade(realitykit::surface_parameters p) {
    float4 custom = p.uniforms().custom_parameter();
    uint material = uint(custom.x) * avatarMaterialStride;
    uint table = uint(custom.z) | (uint(custom.w) << 16);
    uint triangle = uint(round(p.geometry().custom_attribute().x));
    float3 position = (p.uniforms().model_to_world() * float4(p.geometry().model_position(), 1.0)).xyz;
    float3 view = normalize(p.geometry().view_direction());
    float hand = p.geometry().custom_attribute().y;
    // RealityKit stores a right-handed tangent frame; restore the authored tangent sign.
    float3 tangent = abs(hand) > 0.5 ? p.geometry().tangent() * sign(hand) : float3(0.0);
    float3 bitangent = abs(hand) > 0.5 ? p.geometry().bitangent() : float3(0.0);
    auto result = avatarMToon(p.textures().base_color(), p.textures().custom(), material, table, triangle,
        p.geometry().uv0(), custom.y, position, p.geometry().normal(), view, tangent, bitangent);
    float4 render = avatarRow(p.textures().custom(), material + 7);
    if (Cutout && result.alpha < avatarFloat(avatarRow(p.textures().custom(), material + avatarScalarStart + 12))) { discard_fragment(); }
    float3 color = result.color;
    if (Outline) {
        float mixFactor = avatarFloat(avatarRow(p.textures().custom(), material + avatarScalarStart + 7));
        color = avatarRow(p.textures().custom(), material + 5).rgb * mix(float3(1.0), result.color, mixFactor);
    }
    color *= avatarFloat(avatarRow(p.textures().custom(), material + avatarScalarStart + 13));
    p.surface().set_base_color(half3(0.0));
    p.surface().set_emissive_color(half3(color));
    p.surface().set_opacity(half(render.z > 1.5 ? saturate(result.alpha) : 1.0));
    p.surface().set_metallic(0.0h); p.surface().set_roughness(1.0h);
}

[[visible]] void avatarToon(realitykit::surface_parameters p) { avatarShade<false, false>(p); }
[[visible]] void avatarToonMask(realitykit::surface_parameters p) { avatarShade<true, false>(p); }
[[visible]] void avatarOutline(realitykit::surface_parameters p) { avatarShade<false, true>(p); }
[[visible]] void avatarOutlineMask(realitykit::surface_parameters p) { avatarShade<true, true>(p); }

[[visible]] void avatarSurfaceVertex(realitykit::geometry_parameters p) {
    p.geometry().set_custom_attribute(float4(p.geometry().uv1(), 0.0, 0.0));
}

[[visible]] void avatarExpand(realitykit::geometry_parameters p) {
    float4 custom = p.uniforms().custom_parameter();
    uint material = uint(custom.x) * avatarMaterialStride, table = uint(custom.z) | (uint(custom.w) << 16);
    uint triangle = uint(round(p.geometry().uv1().x));
    p.geometry().set_custom_attribute(float4(p.geometry().uv1(), 0.0, 0.0));
    uint maskSlot = material + avatarTextureStart + 8 * avatarTextureStride;
    float2 maskUV = avatarSlotUV(p.textures().base_color(), p.textures().custom(), material, table, triangle, p.geometry().uv0(), 8, custom.y, 1.0, false);
    float mask = avatarTexture(p.textures().base_color(), p.textures().custom(), maskSlot, maskUV, float2(0), float2(0), float4(1.0)).b;
    uint outlineSlot = material + avatarTextureStart + 7 * avatarTextureStride;
    float2 uv = avatarSlotUV(p.textures().base_color(), p.textures().custom(), material, table, triangle, p.geometry().uv0(), 7, custom.y, mask, true);
    float width = avatarFloat(avatarRow(p.textures().custom(), material + avatarScalarStart + 6));
    width *= avatarTexture(p.textures().base_color(), p.textures().custom(), outlineSlot, uv, float2(0), float2(0), float4(1.0)).g;
    float3 worldNormal = p.uniforms().normal_to_world() * p.geometry().normal();
    if (dot(worldNormal, worldNormal) <= 1e-8 || width <= 0.0) { return; }
    worldNormal = normalize(worldNormal);
    if (avatarRow(p.textures().custom(), material + 7).x > 1.5) {
        float4 view = p.uniforms().model_to_view() * float4(p.geometry().model_position(), 1.0);
        float4x4 projection = p.uniforms().view_to_projection();
        float4x4 worldToView = p.uniforms().world_to_view();
        float4 clip = projection * view, delta = projection * worldToView * float4(worldNormal, 0.0);
        float aspect = abs(projection[1][1] / max(abs(projection[0][0]), 1e-6));
        float2 numerator = (delta.xy * clip.w - clip.xy * delta.w) * float2(aspect, 1.0);
        float denominator = length(numerator) - 2.0 * width * clip.w * delta.w;
        if (clip.w <= 0.0 || denominator <= 1e-8) { return; }
        width = 2.0 * width * clip.w * clip.w / denominator;
    }
    p.geometry().set_world_position_offset(worldNormal * width);
}

// Separate shadow passes use the same material, UV animation, transform and sampler data.
struct AvatarShadowVertex { float4 position; float4 uv; };
struct AvatarShadowUniforms { float time; int material; uint table; uint padding; };
struct AvatarShadowVarying {
    float4 position [[position]];
    float2 barycentric;
    uint triangle [[flat]];
};
vertex AvatarShadowVarying avatarShadowVertex(uint index [[vertex_id]], const device AvatarShadowVertex *vertices [[buffer(0)]], constant float4x4 &matrix [[buffer(1)]]) {
    AvatarShadowVertex v = vertices[index];
    return {matrix * v.position, v.uv.xy, uint(v.uv.z)};
}
fragment float4 avatarShadowFragment(AvatarShadowVarying in [[stage_in]], texture2d<half> images [[texture(0)]],
    texture2d<half> parameters [[texture(1)]], constant AvatarShadowUniforms &uniforms [[buffer(0)]]) {
    if (uniforms.material >= 0) {
        uint material = uint(uniforms.material) * avatarMaterialStride;
        float mode = avatarRow(parameters, material + 7).z;
        if (mode > 0.5) {
            uint maskSlot = material + avatarTextureStart + 8 * avatarTextureStride;
            float2 maskUV = avatarSlotUV(images, parameters, material, uniforms.table, in.triangle, in.barycentric, 8, uniforms.time, 1.0, false);
            float mask = avatarTexture(images, parameters, maskSlot, maskUV, dfdx(maskUV), dfdy(maskUV), float4(1.0)).b;
            float2 uv = avatarSlotUV(images, parameters, material, uniforms.table, in.triangle, in.barycentric, 0, uniforms.time, mask, true);
            float alpha = avatarRow(parameters, material).w * avatarTexture(images, parameters, material + avatarTextureStart, uv, dfdx(uv), dfdy(uv), float4(1.0)).w;
            float cutoff = mode < 1.5 ? avatarFloat(avatarRow(parameters, material + avatarScalarStart + 12)) : 0.5;
            if (alpha < cutoff) { discard_fragment(); }
        }
    }
    float high = floor(in.position.z * 2048.0) / 2048.0;
    return float4(high, in.position.z - high, 0.0, 1.0);
}
