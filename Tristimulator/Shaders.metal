//
//  Shaders.metal
//  Tristimulator
//
//  Created by Alex Fry on 2/3/2026.
//

#include <metal_stdlib>
using namespace metal;

struct Vertex {
    float2 position;
    float2 texCoord;
};

struct RasterizerData {
    float4 position [[position]];
    float2 texCoord;
};

struct Uniforms {
    float maxEDRHeadroom;
    float3 padding;
};

vertex RasterizerData vertexShader(
    uint vertexID [[vertex_id]],
    constant Vertex *vertices [[buffer(0)]]
) {
    RasterizerData out;
    out.position = float4(vertices[vertexID].position, 0.0, 1.0);
    out.texCoord = vertices[vertexID].texCoord;
    return out;
}

// ACES tone mapping for HDR display with EDR headroom
float3 acesTonemap(float3 color, float maxOutput) {
    // ACES fitted tone curve
    float a = 2.51;
    float b = 0.03;
    float c = 2.43;
    float d = 0.59;
    float e = 0.14;
    
    // Scale by max output to preserve HDR values
    color = color * maxOutput;
    
    return saturate((color * (a * color + b)) / (color * (c * color + d) + e));
}

fragment float4 fragmentShader(
    RasterizerData in [[stage_in]],
    constant Uniforms &uniforms [[buffer(0)]],
    texture2d<float, access::sample> colorTexture [[texture(0)]],
    sampler textureSampler [[sampler(0)]]
) {
    // Sample the texture (already has exposure + OCIO transform applied on GPU)
    float4 color = colorTexture.sample(textureSampler, in.texCoord);
    
    // For HDR displays, preserve values > 1.0 up to EDR headroom
    float maxComponent = max(max(color.r, color.g), color.b);
    
    if (maxComponent > 1.0) {
        // Scale HDR content to fit within EDR headroom
        float scale = min(uniforms.maxEDRHeadroom, maxComponent);
        color.rgb = color.rgb / maxComponent * scale;
    }
    
    return color;
}

// Simple passthrough fragment for chromaticity density heatmap overlay.
// The heatmap color is already baked into the density texture by the
// chromaticityNormalize compute kernel; we just sample and output it.
fragment float4 chromaticityDensityFragment(
    RasterizerData in [[stage_in]],
    texture2d<float, access::sample> densityTexture [[texture(0)]],
    sampler textureSampler [[sampler(0)]]
) {
    return densityTexture.sample(textureSampler, in.texCoord);
}

// Alternative fragment shader with tone mapping
fragment float4 fragmentShaderTonemap(
    RasterizerData in [[stage_in]],
    constant Uniforms &uniforms [[buffer(0)]],
    texture2d<float, access::sample> colorTexture [[texture(0)]],
    sampler textureSampler [[sampler(0)]]
) {
    float4 color = colorTexture.sample(textureSampler, in.texCoord);
    
    // Apply ACES tone mapping that respects EDR headroom
    // (exposure already applied in scene-linear space)
    color.rgb = acesTonemap(color.rgb, uniforms.maxEDRHeadroom);
    
    return color;
}
