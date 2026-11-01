// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

#include <metal_stdlib>
using namespace metal;

// ── Uniforms ──
// Note: Metal float3 in struct aligns to 16 bytes.
// Swift side uses SIMD3<Float>(12B) + Float _pad(4B) = 16B.
struct FluidUniforms {
    float phase;         // offset 0,  4B  (Swift: Float)
    // [Implicit pad 4B -> float2 requires 8B alignment] (Swift: _pad Float)
    float2 resolution;   // offset 8,  8B  (Swift: SIMD2<Float>)
    float3 color1;       // offset 16, 16B (Swift: SIMD3<Float> + _pad1)
    float3 color2;       // offset 32, 16B (Swift: SIMD3<Float> + _pad2)
    float3 color3;       // offset 48, 16B (Swift: SIMD3<Float> + _pad3)

    float focusMode;     // offset 64, 4B (0=normal, 1=flow)
    float focusProgress; // offset 68, 4B [0, 1]
    float breathSeed;    // offset 72, 4B
    float _pad1;         // offset 76, 4B
    // Total: 80 bytes
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// ── Fullscreen Triangle Vertex — zero vertex buffer required ──
vertex VertexOut fluidVertex(uint vid [[vertex_id]]) {
    float2 pos = float2((vid << 1) & 2, vid & 2);
    VertexOut out;
    out.position = float4(pos * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(pos.x, 1.0 - pos.y);
    return out;
}

// ── Breathing animation model ──
float breathProgress(float x, float seed) {
    float base = smoothstep(0.0, 1.0, x);
    float noise = sin(x * 2.0 + seed) * 0.08;
    return clamp(base + noise, 0.0, 1.0);
}

// ── Pass 1: Draw filled circles with Normal Alpha blending ──
//
// Premultiplied alpha Over composition keeps color saturation in overlap regions.
// Followed by Gaussian blur via MPS.
fragment float4 fluidCirclesFragment(
    VertexOut in [[stage_in]],
    constant FluidUniforms &u [[buffer(0)]]
) {
    float2 uv = in.uv;
    float t = u.phase;
    float aspect = u.resolution.x / u.resolution.y;
    float3 unmultiplied;

    // ── 3 circle trajectories ──
    // Default wandering state
    float2 idleC1 = float2(0.5 + cos(t * 0.65) * 0.3,  0.5 + sin(t * 1.05) * 0.2);
    float2 idleC2 = float2(0.5 + sin(t * 0.45) * 0.4,  0.5 + cos(t * 0.95) * 0.3);
    float2 idleC3 = float2(0.5 + cos(t * 0.35) * 0.25, 0.5 + sin(t * 0.55) * 0.4);

    float2 c1 = idleC1;
    float2 c2 = idleC2;
    float2 c3 = idleC3;

    // ── Circle radii ──
    float baseRadius = 0.54;

    // Breathing scale variance
    float breathScale = breathProgress(u.focusProgress, u.breathSeed);
    float r1 = mix(baseRadius, baseRadius + 0.15 * breathScale, 1.0 - u.focusMode);
    float r2 = baseRadius;
    float r3 = baseRadius;

    // Aspect ratio correction: ensure circular shape in pixel space
    float2 scale_factor = (aspect > 1.0) ? float2(aspect, 1.0) : float2(1.0, 1.0 / aspect);

    float2 d1 = (uv - c1) * scale_factor;
    float2 d2 = (uv - c2) * scale_factor;
    float2 d3 = (uv - c3) * scale_factor;

    // Hard circle masks (wandering mode)
    float mask1_idle = step(length(d1), r1);
    float mask2 = step(length(d2), r2);
    float mask3 = step(length(d3), r3);

    float3 finalC1 = u.color1;
    float3 finalC2 = u.color2;
    float3 finalC3 = u.color3;

    // ── Normal Alpha blending (Over composite, premultiplied alpha) ──
    // Circle 1: Base background layer
    float a1 = clamp(mask1_idle, 0.0, 1.0);
    float3 pm1 = finalC1 * a1;

    // Circle 2: Layered onto Circle 1
    float a2 = 0.8 * mask2;
    float3 pm2 = finalC2 * a2;
    float3 rgb = pm2 + pm1 * (1.0 - a2);
    float alpha = a2 + a1 * (1.0 - a2);

    // Circle 3: Layered onto cumulative buffer
    float a3 = 0.6 * mask3;
    float3 pm3 = finalC3 * a3;
    rgb = pm3 + rgb * (1.0 - a3);
    alpha = a3 + alpha * (1.0 - a3);

    // Convert premultiplied sRGB to premultiplied Linear RGB for physically accurate blur
    unmultiplied = rgb / max(alpha, 1e-5);
    return float4(unmultiplied * alpha, alpha);
}

// ── Pass 3: Blit blurred texture to screen ──
fragment float4 blitTextureFragment(
    VertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    constant float4 &compositeParams [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 c = tex.sample(s, in.uv);

    // Convert from premultiplied Linear RGB back to premultiplied sRGB
    float3 unmultiplied = c.rgb / max(c.a, 1e-5);
    float3 blobColor = max(unmultiplied, 0.0);

    float3 bgColor = compositeParams.xyz;
    float opacity = compositeParams.w;

    // In-GPU background composition: solves black background issue when CAMetalLayer.isOpaque = true
    float3 result = mix(bgColor, blobColor, c.a * opacity);

    return float4(result, 1.0);
}

// ── Cache extraction: Writes blurred RGBA16Float alpha (coverage) to R8 texture ──
// Used during pre-render pass.
fragment float extractCoverageFragment(
    VertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return tex.sample(s, in.uv).a;
}

// ── Cache playback: Interpolates pre-rendered R8 frames + runtime tinting + GPU background blend ──
//
// params.x = Interpolation factor between frames (0~1)
// params.yzw = Blob color (sRGB space)
//
// compositeParams.xyz = Background color (dark=black, light=white)
// compositeParams.w   = Fluid opacity (dark=0.6, light=0.3)
fragment float4 blitCachedFragment(
    VertexOut in [[stage_in]],
    texture2d<float> frameA [[texture(0)]],
    texture2d<float> frameB [[texture(1)]],
    constant float4 &params [[buffer(0)]],
    constant float4 &compositeParams [[buffer(1)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    // Sample cache textures matching screen aspect ratio
    float covA = frameA.sample(s, in.uv).r;
    float covB = frameB.sample(s, in.uv).r;
    float coverage = mix(covA, covB, params.x);

    float3 blobColor = params.yzw;
    float3 bgColor = compositeParams.xyz;
    float opacity = compositeParams.w;

    // In-GPU composition: mix blobColor with bgColor according to coverage
    float3 result = mix(bgColor, blobColor, coverage * opacity);

    return float4(result, 1.0);
}
