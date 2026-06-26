#include <metal_stdlib>
using namespace metal;

constant uint kRows = 32768u;
constant uint kPackedCols = 512u;

[[max_total_threads_per_threadgroup(64)]]
kernel void main_kernel(
    device const float4* matrixData [[buffer(0)]],
    device const float4* vectorData [[buffer(1)]],
    device float4* outData [[buffer(2)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= (kRows / 4u)) return;

    float4 sum = float4(0.0f);
    for (uint col = 0u; col < kPackedCols; col += 16u) {
        uint base = 4u * (gid * kPackedCols + col);
        float4 v0 = vectorData[col + 0u];
        float4 v1 = vectorData[col + 1u];
        float4 v2 = vectorData[col + 2u];
        float4 v3 = vectorData[col + 3u];
        float4 v4 = vectorData[col + 4u];
        float4 v5 = vectorData[col + 5u];
        float4 v6 = vectorData[col + 6u];
        float4 v7 = vectorData[col + 7u];
        float4 v8 = vectorData[col + 8u];
        float4 v9 = vectorData[col + 9u];
        float4 v10 = vectorData[col + 10u];
        float4 v11 = vectorData[col + 11u];
        float4 v12 = vectorData[col + 12u];
        float4 v13 = vectorData[col + 13u];
        float4 v14 = vectorData[col + 14u];
        float4 v15 = vectorData[col + 15u];

        sum.x += dot(matrixData[base + 0u], v0);
        sum.y += dot(matrixData[base + 1u], v0);
        sum.z += dot(matrixData[base + 2u], v0);
        sum.w += dot(matrixData[base + 3u], v0);
        sum.x += dot(matrixData[base + 4u], v1);
        sum.y += dot(matrixData[base + 5u], v1);
        sum.z += dot(matrixData[base + 6u], v1);
        sum.w += dot(matrixData[base + 7u], v1);
        sum.x += dot(matrixData[base + 8u], v2);
        sum.y += dot(matrixData[base + 9u], v2);
        sum.z += dot(matrixData[base + 10u], v2);
        sum.w += dot(matrixData[base + 11u], v2);
        sum.x += dot(matrixData[base + 12u], v3);
        sum.y += dot(matrixData[base + 13u], v3);
        sum.z += dot(matrixData[base + 14u], v3);
        sum.w += dot(matrixData[base + 15u], v3);
        sum.x += dot(matrixData[base + 16u], v4);
        sum.y += dot(matrixData[base + 17u], v4);
        sum.z += dot(matrixData[base + 18u], v4);
        sum.w += dot(matrixData[base + 19u], v4);
        sum.x += dot(matrixData[base + 20u], v5);
        sum.y += dot(matrixData[base + 21u], v5);
        sum.z += dot(matrixData[base + 22u], v5);
        sum.w += dot(matrixData[base + 23u], v5);
        sum.x += dot(matrixData[base + 24u], v6);
        sum.y += dot(matrixData[base + 25u], v6);
        sum.z += dot(matrixData[base + 26u], v6);
        sum.w += dot(matrixData[base + 27u], v6);
        sum.x += dot(matrixData[base + 28u], v7);
        sum.y += dot(matrixData[base + 29u], v7);
        sum.z += dot(matrixData[base + 30u], v7);
        sum.w += dot(matrixData[base + 31u], v7);
        sum.x += dot(matrixData[base + 32u], v8);
        sum.y += dot(matrixData[base + 33u], v8);
        sum.z += dot(matrixData[base + 34u], v8);
        sum.w += dot(matrixData[base + 35u], v8);
        sum.x += dot(matrixData[base + 36u], v9);
        sum.y += dot(matrixData[base + 37u], v9);
        sum.z += dot(matrixData[base + 38u], v9);
        sum.w += dot(matrixData[base + 39u], v9);
        sum.x += dot(matrixData[base + 40u], v10);
        sum.y += dot(matrixData[base + 41u], v10);
        sum.z += dot(matrixData[base + 42u], v10);
        sum.w += dot(matrixData[base + 43u], v10);
        sum.x += dot(matrixData[base + 44u], v11);
        sum.y += dot(matrixData[base + 45u], v11);
        sum.z += dot(matrixData[base + 46u], v11);
        sum.w += dot(matrixData[base + 47u], v11);
        sum.x += dot(matrixData[base + 48u], v12);
        sum.y += dot(matrixData[base + 49u], v12);
        sum.z += dot(matrixData[base + 50u], v12);
        sum.w += dot(matrixData[base + 51u], v12);
        sum.x += dot(matrixData[base + 52u], v13);
        sum.y += dot(matrixData[base + 53u], v13);
        sum.z += dot(matrixData[base + 54u], v13);
        sum.w += dot(matrixData[base + 55u], v13);
        sum.x += dot(matrixData[base + 56u], v14);
        sum.y += dot(matrixData[base + 57u], v14);
        sum.z += dot(matrixData[base + 58u], v14);
        sum.w += dot(matrixData[base + 59u], v14);
        sum.x += dot(matrixData[base + 60u], v15);
        sum.y += dot(matrixData[base + 61u], v15);
        sum.z += dot(matrixData[base + 62u], v15);
        sum.w += dot(matrixData[base + 63u], v15);
    }
    outData[gid] = sum;
}
