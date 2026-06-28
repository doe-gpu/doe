#include <metal_stdlib>
using namespace metal;

constant uint kBufferSize = 1024u;
constant uint kBufferMask = kBufferSize - 1u;

[[max_total_threads_per_threadgroup(1)]]
kernel void main_kernel(device uint* inout_data [[buffer(0)]])
{
    threadgroup uint wg_data[1024];

    uint accum = inout_data[0];
    for (uint i = 0u; i < kBufferSize; i++) {
        wg_data[i] = inout_data[i];
    }
    for (uint i = 0u; i < 1000000u; i++) {
        uint idx = (i + accum) & kBufferMask;
        accum = (accum ^ wg_data[idx]) + 123u;
    }
    inout_data[0] = accum;
}
