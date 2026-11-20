//
//  PixelReduction.metal
//  Tristimulator
//
//  Finds the per-channel maximum of a given texture using a single-pass
//  threadgroup tree reduction.
//
//  Dispatch: threadgroups of exactly 16×16 = 256 threads.
//  Each thread reads one pixel; out-of-bounds threads contribute 0.
//  Thread 0 of each group writes its local maximum to groupMaxes[].
//  The host then scans the small groupMaxes buffer to get the global maximum.
//

#include <metal_stdlib>
using namespace metal;

kernel void textureMaxReduce(
    texture2d<float, access::read> tex         [[texture(0)]],
    device   float4*               groupMaxes  [[buffer(0)]],
    uint2    gid     [[thread_position_in_grid]],
    uint     lid     [[thread_index_in_threadgroup]],
    uint2    tgid    [[threadgroup_position_in_grid]],
    uint2    tgCount [[threadgroups_per_grid]]
) {
    // Read pixel; threads that fall outside the texture contribute 0.
    uint w = tex.get_width();
    uint h = tex.get_height();
    float4 val = (gid.x < w && gid.y < h) ? tex.read(gid) : float4(0.0);
    // Ignore alpha — only RGB contributes to the peak measurement.
    val.w = 0.0;

    // Store in threadgroup-shared array (256 entries × 16 bytes = 4 KB).
    threadgroup float4 localMax[256];
    localMax[lid] = val;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Tree reduction: 256 → 128 → 64 → 32 → 16 → 8 → 4 → 2 → 1.
    for (uint s = 128; s > 0; s >>= 1) {
        if (lid < s) {
            localMax[lid] = max(localMax[lid], localMax[lid + s]);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    // Thread 0 writes the per-group result.
    if (lid == 0) {
        groupMaxes[tgid.y * tgCount.x + tgid.x] = localMax[0];
    }
}
