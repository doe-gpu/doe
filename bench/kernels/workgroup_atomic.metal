#include <metal_stdlib>
using namespace metal;

constant uint kWorkgroupSize = 256u;
constant uint kWorkgroupMask = kWorkgroupSize - 1u;

[[max_total_threads_per_threadgroup(256)]]
kernel void main_kernel(
    device uint* outVal [[buffer(0)]],
    uint lid [[thread_position_in_threadgroup]],
    uint gid [[thread_position_in_grid]])
{
    threadgroup atomic_uint wg[256];

    uint accum = outVal[gid];
    atomic_store_explicit(&wg[lid], accum + gid, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint i = 0u; i < kWorkgroupSize; i++) {
        accum = atomic_load_explicit(&wg[(i + accum) & kWorkgroupMask], memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    outVal[gid] = accum;
}
