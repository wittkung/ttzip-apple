// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// ── Organic Fluid Shader (Domain Warping) ──
//
// Visual Principles:
//   1. Generates base texture field using Simplex noise.
//   2. Displaces sampling coordinates with the noise's own output (Domain Warping).
//   3. Layered composition + time-driven evolution -> aurora / deep sea current aesthetic.
//
// Performance Notes:
//   - [[ stitchable ]] functions are invoked per-pixel by SwiftUI directly.
//   - Pure ALU noise computations without texture fetches, bandwidth friendly.

static float3 mod289(float3 x) {
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

static float2 mod289(float2 x) {
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

static float3 permute(float3 x) {
    return mod289(((x * 34.0) + 1.0) * x);
}

/// 2D Simplex noise, returns ∈ [-1, 1]
static float snoise(float2 v) {
    const float4 C = float4(
        0.211324865405187,   // (3.0-sqrt(3.0))/6.0
        0.366025403784439,   //  0.5*(sqrt(3.0)-1.0)
       -0.577350269189626,   // -1.0 + 2.0 * C.x
        0.024390243902439    //  1.0 / 41.0
    );
    float2 i;
    float2 x0;
    float2 i1;
    float4 x12;
    float3 p;
    float3 m;
    float3 x_;
    float3 h;
    float3 ox;
    float3 a0;
    float3 g;

    // First corner coordinates
    i = floor(v + dot(v, C.yy));
    x0 = v - i + dot(i, C.xx);

    // Other two corners
    i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;

    // Permutation
    i = mod289(i);
    p = permute(permute(i.y + float3(0.0, i1.y, 1.0)) + i.x + float3(0.0, i1.x, 1.0));

    m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);
    m = m * m;
    m = m * m;

    // Gradients
    x_ = 2.0 * fract(p * C.www) - 1.0;
    h = abs(x_) - 0.5;
    ox = floor(x_ + 0.5);
    a0 = x_ - ox;

    // Normalized gradients (approximate to avoid rsqrt)
    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);

    // Compute contributions
    g.x = a0.x * x0.x + h.x * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;

    return 130.0 * dot(m, g);
}

// ── FBM (Fractional Brownian Motion): Layered noise summation ──
static float fbm(float2 p, float time) {
    float value = 0.0;
    float amplitude = 0.5;
    float2 shift = float2(100.0, 100.0);

    // 4-octave summation: frequency * 2, amplitude * 0.5
    for (int i = 0; i < 4; i++) {
        value += amplitude * snoise(p + time * 0.15);
        p = p * 2.0 + shift;
        amplitude *= 0.5;
        time *= 1.1;  // Slight octave time variance to enrich complexity
    }
    return value;
}

// ── Main Shader: Domain Warping Organic Fluid ──
[[ stitchable ]] half4 organicFluid(
    float2 position,
    half4 color,
    float2 size,
    float time,
    half4 baseColor,
    float speed,
    float opacity,
    float isDark
) {
    float2 uv;
    float aspect;
    float2 p;
    float t;
    float2 q;
    float2 r;
    float f;
    float3 bc;
    float3 highlight;
    float3 shadow;
    float3 fluidColor;
    float hueShift;
    float3 bgColor;
    float coverage;
    float3 result;

    uv = position / size;
    aspect = size.x / size.y;
    p = float2(uv.x * aspect, uv.y) * 2.5;

    t = time * speed;

    // ── First Domain Warping layer ──
    q = float2(
        fbm(p + float2(0.0, 0.0), t),
        fbm(p + float2(5.2, 1.3), t)
    );

    // ── Second Domain Warping layer (nested) ──
    r = float2(
        fbm(p + 4.0 * q + float2(1.7, 9.2), t * 0.8),
        fbm(p + 4.0 * q + float2(8.3, 2.8), t * 0.8)
    );

    // Final noise value sampled with double-warped coordinates
    f = fbm(p + 4.0 * r, t * 0.6) * 0.5 + 0.5;

    // ── Color Blending ──
    bc = float3(baseColor.rgb);
    highlight = clamp(bc * 1.3, 0.0, 1.0);
    shadow = bc * 0.4;
    fluidColor = mix(shadow, highlight, f);

    // Subtle hue shift based on first layer warping
    hueShift = (q.x + q.y) * 0.08;
    fluidColor.r += hueShift * 0.5;
    fluidColor.b -= hueShift * 0.3;
    fluidColor = clamp(fluidColor, 0.0, 1.0);

    // ── Background Blending ──
    bgColor = isDark > 0.5 ? float3(0.0) : float3(1.0);
    coverage = smoothstep(0.15, 0.85, f);
    result = mix(bgColor, fluidColor, coverage * opacity);

    return half4(half3(result), 1.0h);
}
