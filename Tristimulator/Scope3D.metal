//
//  Scope3D.metal
//  Tristimulator
//
//  Render shaders for the 3D Yxy / JMh scopes (Scope3DView.swift):
//    - point cloud written by chromaticityPoints / jmhPoints
//    - marker lines (locus, gamuts, axes, ticks, rings) as screen-space quads
//    - Core Text labels from a texture atlas as camera-facing quads
//  All three take the 64-byte model-view-projection matrix at buffer(1).
//

#include <metal_stdlib>
using namespace metal;

struct Scope3DPoint {
    float4 position;   // scope space (xyz)
    float4 color;
};

struct Scope3DViewUniforms {
    float2 viewportSize;    // drawable size in pixels
    float  pointSize;       // pixels
    float  cameraDistance;  // world units, for label depth fade
};

// ---------------------------------------------------------------------------
// Points
// ---------------------------------------------------------------------------

struct Scope3DPointOut {
    float4 position [[position]];
    float4 color;
    float  size [[point_size]];
};

vertex Scope3DPointOut scope3DPointVertex(
    uint vid [[vertex_id]],
    const device Scope3DPoint* points   [[buffer(0)]],
    constant float4x4& mvp              [[buffer(1)]],
    constant Scope3DViewUniforms& u     [[buffer(2)]]
) {
    Scope3DPointOut out;
    out.position = mvp * float4(points[vid].position.xyz, 1.0);
    out.color    = points[vid].color;
    out.size     = u.pointSize;
    return out;
}

fragment float4 scope3DPointFragment(
    Scope3DPointOut in [[stage_in]],
    float2 pc [[point_coord]]
) {
    float2 d = pc - 0.5;
    if (dot(d, d) > 0.25) discard_fragment();
    return float4(in.color.rgb, 1.0);
}

// ---------------------------------------------------------------------------
// Thick lines: one instance per segment, 4-vertex triangle strip expanded
// perpendicular to the projected segment in screen space.
// ---------------------------------------------------------------------------

struct Scope3DLine {
    float4 a;        // xyz endpoint A (scope space)
    float4 b;        // xyz endpoint B
    float4 color;    // straight (non-premultiplied) RGBA
    float4 params;   // x = width in pixels
};

struct Scope3DColorOut {
    float4 position [[position]];
    float4 color;
};

vertex Scope3DColorOut scope3DLineVertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    const device Scope3DLine* lines     [[buffer(0)]],
    constant float4x4& mvp              [[buffer(1)]],
    constant Scope3DViewUniforms& u     [[buffer(2)]]
) {
    Scope3DLine l = lines[iid];
    float4 ca = mvp * float4(l.a.xyz, 1.0);
    float4 cb = mvp * float4(l.b.xyz, 1.0);
    float wa = max(ca.w, 1e-4);
    float wb = max(cb.w, 1e-4);
    float2 halfVP = 0.5 * u.viewportSize;
    float2 sa = ca.xy / wa * halfVP;
    float2 sb = cb.xy / wb * halfVP;
    float2 dir = sb - sa;
    float len = length(dir);
    dir = (len > 1e-5) ? dir / len : float2(1.0, 0.0);
    float2 n = float2(-dir.y, dir.x);

    // Strip order: 0 = A-, 1 = B-, 2 = A+, 3 = B+
    bool useB   = (vid & 1u) != 0u;
    float side  = (vid < 2u) ? -1.0 : 1.0;
    float4 c    = useB ? cb : ca;
    float  w    = useB ? wb : wa;
    float2 off  = n * side * (l.params.x * 0.5);
    c.xy += off / halfVP * w;

    Scope3DColorOut out;
    out.position = c;
    out.color = l.color;
    return out;
}

fragment float4 scope3DLineFragment(Scope3DColorOut in [[stage_in]]) {
    // Premultiplied output (pipeline blends one / oneMinusSourceAlpha).
    return float4(in.color.rgb * in.color.a, in.color.a);
}

// ---------------------------------------------------------------------------
// Labels: camera-facing instanced quads sampling a Core Text atlas.
// Drawn after geometry with depth testing off; alpha fades with distance.
// ---------------------------------------------------------------------------

struct Scope3DLabel {
    float4 anchor;      // xyz anchor (scope space)
    float4 color;       // straight RGBA tint
    float4 uvRect;      // u, vTop, width, height in atlas UV
    float4 sizeOffset;  // xy = quad size (px), zw = bottom-left offset from anchor (px)
};

struct Scope3DLabelOut {
    float4 position [[position]];
    float4 color;
    float2 uv;
};

vertex Scope3DLabelOut scope3DLabelVertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    const device Scope3DLabel* labels   [[buffer(0)]],
    constant float4x4& mvp              [[buffer(1)]],
    constant Scope3DViewUniforms& u     [[buffer(2)]]
) {
    Scope3DLabel l = labels[iid];
    float2 corner = float2(float(vid & 1u), float(vid >> 1u));   // (0,0) BL … (1,1) TR
    float4 c = mvp * float4(l.anchor.xyz, 1.0);
    float2 px = l.sizeOffset.zw + corner * l.sizeOffset.xy;
    c.xy += px / (0.5 * u.viewportSize) * c.w;

    // Fade labels on the far side of the scope (cube radius ~1.5 world units).
    float fade = clamp(1.0 - (c.w - (u.cameraDistance - 1.5)) / 3.0 * 0.75, 0.25, 1.0);

    Scope3DLabelOut out;
    out.position = c;
    out.color = float4(l.color.rgb, l.color.a * fade);
    out.uv = float2(l.uvRect.x + corner.x * l.uvRect.z,
                    l.uvRect.y + (1.0 - corner.y) * l.uvRect.w);
    return out;
}

fragment float4 scope3DLabelFragment(
    Scope3DLabelOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float a = atlas.sample(s, in.uv).a * in.color.a;
    return float4(in.color.rgb * a, a);
}
