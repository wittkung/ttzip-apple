// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

#include <metal_stdlib>
using namespace metal;

struct TileVertexIn {
    float2 position [[attribute(0)]];
    float2 uv [[attribute(1)]];
};

struct TileVertexOut {
    float4 position [[position]];
    float2 uv;
};

struct TileUniforms {
    float4x4 mvp;
    float2 viewportSize;
    float2 tileOffset;
    float2 tileScale;
    float opacity;
    float lodLevel;
    float2 _padding;
};

vertex TileVertexOut tileVertexShader(
    uint vertexID [[vertex_id]],
    constant TileVertexIn* vertices [[buffer(0)]],
    constant TileUniforms& uniforms [[buffer(1)]]
) {
    TileVertexOut out;
    TileVertexIn in = vertices[vertexID];

    // Position quad with offset and scale in normalized device coordinates
    float2 localPos = in.position * uniforms.tileScale + uniforms.tileOffset;
    out.position = uniforms.mvp * float4(localPos, 0.0, 1.0);
    out.uv = in.uv;

    return out;
}

fragment float4 tileFragmentShader(
    TileVertexOut in [[stage_in]],
    texture2d<float> tileTexture [[texture(0)]],
    sampler tileSampler [[sampler(0)]],
    constant TileUniforms& uniforms [[buffer(1)]]
) {
    float4 color = tileTexture.sample(tileSampler, in.uv);
    color.a *= uniforms.opacity;
    return color;
}
