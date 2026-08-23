// matmul_mma_bench — simdgroup MMA matmul targeting M4 FP32 peak (~4 TFLOPS)
//
// Uses simdgroup_matrix_multiply_accumulate for near-peak ALU utilization.
// Compare with matmul_dvfs_bench.m (naive tiled, ~560 GFLOPS) to show
// the difference between a DVFS demo kernel and a peak-throughput kernel.
//
// Build: xcrun clang -framework Metal -framework Foundation -O2 -o matmul_mma_bench matmul_mma_bench.m
// Run:   ./matmul_mma_bench

#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach_time.h>

static NSString *mmaShader = @
"#include <metal_stdlib>\n"
"#include <metal_simdgroup_matrix>\n"
"using namespace metal;\n"
"\n"
"kernel void matmul_mma(\n"
"    device const float *A [[buffer(0)]],\n"
"    device const float *B [[buffer(1)]],\n"
"    device float *C       [[buffer(2)]],\n"
"    constant uint &M      [[buffer(3)]],\n"
"    constant uint &N      [[buffer(4)]],\n"
"    constant uint &K      [[buffer(5)]],\n"
"    uint sid [[simdgroup_index_in_threadgroup]],\n"
"    uint2 tgid [[threadgroup_position_in_grid]])\n"
"{\n"
"    const uint BM = 32, BN = 32, BK = 8;\n"
"    uint sg_row = sid / (BN / 8);\n"
"    uint sg_col = sid % (BN / 8);\n"
"    uint row = tgid.y * BM + sg_row * 8;\n"
"    uint col = tgid.x * BN + sg_col * 8;\n"
"    if (row >= M || col >= N) return;\n"
"\n"
"    simdgroup_float8x8 acc = simdgroup_float8x8(0);\n"
"    for (uint k = 0; k < K; k += BK) {\n"
"        simdgroup_float8x8 a, b;\n"
"        simdgroup_load(a, A + row * K + k, K);\n"
"        simdgroup_load(b, B + k * N + col, N);\n"
"        simdgroup_multiply_accumulate(acc, a, b, acc);\n"
"    }\n"
"    simdgroup_store(acc, C + row * N + col, N);\n"
"}\n";

int main(int argc, char **argv) {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) { fprintf(stderr, "No Metal device\n"); return 1; }
    printf("Device: %s\n", [[dev name] UTF8String]);

    NSError *err = nil;
    MTLCompileOptions *opts = [[MTLCompileOptions alloc] init];
    opts.languageVersion = MTLLanguageVersion3_0;
    id<MTLLibrary> lib = [dev newLibraryWithSource:mmaShader options:opts error:&err];
    if (!lib) {
        fprintf(stderr, "Shader compile error: %s\n", [[err description] UTF8String]);
        return 1;
    }
    id<MTLFunction> func = [lib newFunctionWithName:@"matmul_mma"];
    id<MTLComputePipelineState> pso = [dev newComputePipelineStateWithFunction:func error:&err];
    if (!pso) { fprintf(stderr, "PSO error: %s\n", [[err description] UTF8String]); return 1; }
    id<MTLCommandQueue> queue = [dev newCommandQueue];

    printf("Thread execution width: %lu\n", (unsigned long)[pso threadExecutionWidth]);
    printf("Max threads/threadgroup: %lu\n\n", (unsigned long)[pso maxTotalThreadsPerThreadgroup]);

    uint32_t sizes[] = {256, 512, 1024, 2048, 4096};
    int n_sizes = sizeof(sizes) / sizeof(sizes[0]);
    int csv = argc > 1 && strcmp(argv[1], "--csv") == 0;

    if (csv) {
        printf("N,ms,GFLOPS\n");
    } else {
        printf("%-8s %10s %10s %10s\n", "Size", "Best ms", "GFLOPS", "Util%");
        printf("%-8s %10s %10s %10s\n", "----", "-------", "------", "-----");
    }

    for (int s = 0; s < n_sizes; s++) {
        uint32_t N = sizes[s];
        uint32_t M = N, K = N;

        id<MTLBuffer> bufA = [dev newBufferWithLength:M*K*4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> bufB = [dev newBufferWithLength:K*N*4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> bufC = [dev newBufferWithLength:M*N*4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> bufM = [dev newBufferWithBytes:&M length:4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> bufN = [dev newBufferWithBytes:&N length:4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> bufK = [dev newBufferWithBytes:&K length:4 options:MTLResourceStorageModeShared];

        float *pA = (float *)[bufA contents];
        float *pB = (float *)[bufB contents];
        for (uint32_t i = 0; i < M * K; i++) pA[i] = (float)(i % 17) * 0.01f;
        for (uint32_t i = 0; i < K * N; i++) pB[i] = (float)(i % 13) * 0.01f;

        // 32x32 tile per threadgroup, 4 simdgroups (each 8x8)
        MTLSize tg = MTLSizeMake(128, 1, 1); // 4 simdgroups × 32 threads
        MTLSize grid = MTLSizeMake((N + 31) / 32, (M + 31) / 32, 1);

        int warmup = N <= 1024 ? 10 : 3;
        int timed = N <= 1024 ? 20 : 5;

        for (int r = 0; r < warmup; r++) {
            @autoreleasepool {
                id<MTLCommandBuffer> cb = [queue commandBuffer];
                id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
                [enc setComputePipelineState:pso];
                [enc setBuffer:bufA offset:0 atIndex:0];
                [enc setBuffer:bufB offset:0 atIndex:1];
                [enc setBuffer:bufC offset:0 atIndex:2];
                [enc setBuffer:bufM offset:0 atIndex:3];
                [enc setBuffer:bufN offset:0 atIndex:4];
                [enc setBuffer:bufK offset:0 atIndex:5];
                [enc dispatchThreadgroups:grid threadsPerThreadgroup:tg];
                [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
            }
        }

        double best = 1e9;
        for (int r = 0; r < timed; r++) {
            @autoreleasepool {
                id<MTLCommandBuffer> cb = [queue commandBuffer];
                id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
                [enc setComputePipelineState:pso];
                [enc setBuffer:bufA offset:0 atIndex:0];
                [enc setBuffer:bufB offset:0 atIndex:1];
                [enc setBuffer:bufC offset:0 atIndex:2];
                [enc setBuffer:bufM offset:0 atIndex:3];
                [enc setBuffer:bufN offset:0 atIndex:4];
                [enc setBuffer:bufK offset:0 atIndex:5];
                [enc dispatchThreadgroups:grid threadsPerThreadgroup:tg];
                [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
                double ms = ([cb GPUEndTime] - [cb GPUStartTime]) * 1000.0;
                if (ms < best) best = ms;
            }
        }

        double flops = 2.0 * M * N * K;
        double gflops = flops / (best * 1e6);
        // M4 10-core theoretical: ~4.6 TFLOPS FP32
        double util = gflops / 4600.0 * 100.0;

        if (csv) {
            printf("%u,%.4f,%.1f\n", N, best, gflops);
        } else {
            printf("%-8u %10.4f %10.1f %9.1f%%\n", N, best, gflops, util);
        }
        fflush(stdout);
    }

    // Correctness: 64x64 ones
    {
        uint32_t N = 64, M = 64, K = 64;
        id<MTLBuffer> bA = [dev newBufferWithLength:M*K*4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> bB = [dev newBufferWithLength:K*N*4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> bC = [dev newBufferWithLength:M*N*4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> bM = [dev newBufferWithBytes:&M length:4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> bN = [dev newBufferWithBytes:&N length:4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> bK = [dev newBufferWithBytes:&K length:4 options:MTLResourceStorageModeShared];
        float *pA = (float *)[bA contents]; for (uint32_t i = 0; i < M*K; i++) pA[i] = 1.0f;
        float *pB = (float *)[bB contents]; for (uint32_t i = 0; i < K*N; i++) pB[i] = 1.0f;
        memset([bC contents], 0, M*N*4);

        @autoreleasepool {
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
            [enc setComputePipelineState:pso];
            [enc setBuffer:bA offset:0 atIndex:0]; [enc setBuffer:bB offset:0 atIndex:1];
            [enc setBuffer:bC offset:0 atIndex:2]; [enc setBuffer:bM offset:0 atIndex:3];
            [enc setBuffer:bN offset:0 atIndex:4]; [enc setBuffer:bK offset:0 atIndex:5];
            MTLSize g = MTLSizeMake((N+31)/32, (M+31)/32, 1);
            [enc dispatchThreadgroups:g threadsPerThreadgroup:MTLSizeMake(128,1,1)];
            [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
        }
        float *pC = (float *)[bC contents];
        int ok = 1;
        for (uint32_t i = 0; i < M*N && ok; i++)
            if (fabsf(pC[i] - (float)K) > 1.0f) ok = 0;
        printf("\nCorrectness (64x64 ones): %s (C[0]=%.1f, expected=%.1f)\n",
               ok ? "PASS" : "FAIL", pC[0], (float)K);
    }

    printf("\nNote: M4 10-core FP32 theoretical peak ~4.6 TFLOPS\n");
    printf("      FP16 peak ~9.2 TFLOPS (2x FP32 rate)\n");
    return 0;
}
