//
//  OCIOShaders.metal
//  Tristimulator
//
//  GPU-accelerated OCIO color transforms with scene-linear exposure
//

#include <metal_stdlib>
using namespace metal;

struct OCIOUniforms {
    float exposure;           // Exposure in stops
    float padding[3];         // Alignment
};

// This will be replaced with OCIO-generated shader code at runtime
// For now, this is a placeholder structure
kernel void applyExposureAndOCIO(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    texture3d<float, access::sample> lut3D [[texture(2)]],
    constant OCIOUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    // Check bounds
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) {
        return;
    }
    
    // Read input pixel (scene-linear)
    float4 color = inputTexture.read(gid);
    
    // Apply exposure in scene-linear space
    float exposureMultiplier = exp2(uniforms.exposure);
    color.rgb *= exposureMultiplier;
    
    // OCIO transform will be inserted here by the GPU shader generator
    // For now, pass through
    // In real implementation, this section will be replaced with generated OCIO code
    
    // Sample 3D LUT if available
    // float3 lutCoord = color.rgb; // Needs proper scaling based on LUT size
    // color.rgb = lut3D.sample(sampler(filter::linear), lutCoord).rgb;
    
    // Write output
    outputTexture.write(color, gid);
}

// Simpler version without 3D LUT (for transforms that don't need it)
kernel void applyExposureAndOCIOSimple(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    constant OCIOUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    // Check bounds
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) {
        return;
    }
    
    // Read input pixel (scene-linear)
    float4 color = inputTexture.read(gid);
    
    // Apply exposure in scene-linear space
    float exposureMultiplier = exp2(uniforms.exposure);
    color.rgb *= exposureMultiplier;
    
    // OCIO transform code will be inserted here
    // Placeholder: pass through for now
    
    // Write output
    outputTexture.write(color, gid);
}
