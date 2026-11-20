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

fragment float4 fragmentShader(
    RasterizerData in [[stage_in]],
    constant Uniforms &uniforms [[buffer(0)]],
    texture2d<float, access::sample> colorTexture [[texture(0)]],
    sampler textureSampler [[sampler(0)]]
) {
    float4 color = colorTexture.sample(textureSampler, in.texCoord);

    float maxComponent = max(max(color.r, color.g), color.b);

    if (maxComponent > 1.0) {
        float scale = min(uniforms.maxEDRHeadroom, maxComponent);
        color.rgb = color.rgb / maxComponent * scale;
    }

    return color;
}
