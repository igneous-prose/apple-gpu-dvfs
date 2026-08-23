// M4 GPU DVFS Voltage Corner Benchmark
// Drives GPU to each P-state via controlled ALU intensity,
// measures frequency + power via powermetrics concurrently.
//
// Build: xcrun clang -framework Metal -framework Foundation -o gpu_dvfs_bench gpu_dvfs_bench.m
// Run:   sudo ./gpu_dvfs_bench           (needs sudo for powermetrics)
//   or:  ./gpu_dvfs_bench --no-power     (skip powermetrics, just run compute)

#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>
#include <mach/mach_time.h>

// Kernel: variable-intensity FMA loop. iterations controls ALU pressure.
static NSString *shaderSource = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"\n"
"kernel void stress(device float4 *buf [[buffer(0)]],\n"
"                   constant uint &iterations [[buffer(1)]],\n"
"                   uint tid [[thread_position_in_grid]]) {\n"
"    float4 acc = float4(tid * 0.001f);\n"
"    float4 mul = float4(1.0001f, 0.9999f, 1.0002f, 0.9998f);\n"
"    float4 add = float4(0.0001f, -0.0001f, 0.0002f, -0.0002f);\n"
"    for (uint i = 0; i < iterations; i++) {\n"
"        acc = fma(acc, mul, add);\n"
"        acc = fma(acc, mul, add);\n"
"        acc = fma(acc, mul, add);\n"
"        acc = fma(acc, mul, add);\n"
"    }\n"
"    buf[tid] = acc;\n"
"}\n";

typedef struct {
    uint32_t freq_hz;
    uint32_t voltage_mv;
} PerfState;

static const PerfState M4_PERF_STATES[16] = {
    {        0,  125}, // P0  idle/retention
    {338000000,  615}, // P1
    {618000000,  645}, // P2
    {796000000,  680}, // P3
    {928000000,  725}, // P4
    {952000000,  780}, // P5  corner-A
    {1056000000, 780}, // P6  corner-A (higher freq, same V)
    {1053000000, 835}, // P7  corner-B
    {1170000000, 835}, // P8  corner-B
    {1152000000, 875}, // P9  corner-C
    {1278000000, 875}, // P10 corner-C
    {1204000000, 905}, // P11 corner-D
    {1338000000, 905}, // P12 corner-D
    {1326000000, 980}, // P13 corner-E
    {1470000000, 980}, // P14 corner-E
    {1578000000,1055}, // P15 peak
};

static volatile int g_running = 1;

static void sig_handler(int sig) { g_running = 0; }

static double mach_to_ms(uint64_t elapsed) {
    static mach_timebase_info_data_t info = {0};
    if (info.denom == 0) mach_timebase_info(&info);
    return (double)elapsed * info.numer / info.denom / 1e6;
}

// Sweep: run compute at increasing intensity levels, hold each for
// enough time for DVFS to settle and powermetrics to sample.
int main(int argc, char **argv) {
    int use_power = 1;
    int hold_secs = 4;       // seconds per intensity level
    int pm_interval_ms = 200; // powermetrics sample interval

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--no-power") == 0) use_power = 0;
        else if (strcmp(argv[i], "--hold") == 0 && i+1 < argc) hold_secs = atoi(argv[++i]);
    }

    signal(SIGINT, sig_handler);

    // Metal setup
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) { fprintf(stderr, "No Metal device\n"); return 1; }
    printf("Device: %s\n", [[dev name] UTF8String]);
    printf("GPU cores: estimated from device\n\n");

    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:shaderSource options:nil error:&err];
    if (!lib) { fprintf(stderr, "Shader compile: %s\n", [[err description] UTF8String]); return 1; }
    id<MTLFunction> func = [lib newFunctionWithName:@"stress"];
    id<MTLComputePipelineState> pso = [dev newComputePipelineStateWithFunction:func error:&err];
    if (!pso) { fprintf(stderr, "PSO: %s\n", [[err description] UTF8String]); return 1; }

    printf("Max threads/group: %lu\n", (unsigned long)[pso maxTotalThreadsPerThreadgroup]);
    printf("Thread execution width: %lu\n\n", (unsigned long)[pso threadExecutionWidth]);

    // Buffer: 1M float4s = 16 MB
    uint32_t n_threads = 1024 * 1024;
    id<MTLBuffer> buf = [dev newBufferWithLength:n_threads * sizeof(float) * 4
                                        options:MTLResourceStorageModeShared];
    id<MTLBuffer> iter_buf = [dev newBufferWithLength:sizeof(uint32_t)
                                             options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> queue = [dev newCommandQueue];

    // Print DVFS table
    printf("=== M4 GPU DVFS Table (from device tree) ===\n");
    printf("P-state | Freq MHz | Voltage mV | Corner\n");
    printf("--------|----------|------------|-------\n");
    const char *corners[] = {
        "idle", "", "", "", "",
        "A-lo", "A-hi", "B-lo", "B-hi",
        "C-lo", "C-hi", "D-lo", "D-hi",
        "E-lo", "E-hi", "peak"
    };
    for (int i = 0; i < 16; i++) {
        printf("  P%-2d   |  %5u   |    %4u    | %s\n",
               i, M4_PERF_STATES[i].freq_hz / 1000000,
               M4_PERF_STATES[i].voltage_mv, corners[i]);
    }
    printf("\n");

    // Intensity sweep: vary iterations to push DVFS through corners.
    // Low iterations = low ALU pressure = low P-state.
    // High iterations = sustained compute = high P-state.
    uint32_t intensity_levels[] = {
        1,        // near-idle
        4,        // minimal
        16,       // light
        64,       // moderate
        256,      // medium
        1024,     // heavy
        4096,     // very heavy
        16384,    // sustained peak
        65536,    // max stress
    };
    int n_levels = sizeof(intensity_levels) / sizeof(intensity_levels[0]);

    // Start powermetrics in background if requested
    pid_t pm_pid = 0;
    char pm_outfile[256];
    snprintf(pm_outfile, sizeof(pm_outfile), "/tmp/gpu_dvfs_pm_%d.log", getpid());

    if (use_power) {
        pm_pid = fork();
        if (pm_pid == 0) {
            char interval_str[32];
            snprintf(interval_str, sizeof(interval_str), "%d", pm_interval_ms);
            // Run for entire sweep duration + margin
            char count_str[32];
            int total_samples = (n_levels * hold_secs * 1000) / pm_interval_ms + 20;
            snprintf(count_str, sizeof(count_str), "%d", total_samples);

            freopen(pm_outfile, "w", stdout);
            execlp("sudo", "sudo", "powermetrics",
                   "--samplers", "gpu_power",
                   "-i", interval_str,
                   "-n", count_str,
                   NULL);
            _exit(1);
        }
        printf("powermetrics pid=%d → %s\n", pm_pid, pm_outfile);
        usleep(500000); // let it start
    }

    printf("\n=== Sweep: %d levels × %ds hold ===\n\n", n_levels, hold_secs);
    printf("Level | Iters  | Dispatches | Avg ms/dispatch | Status\n");
    printf("------|--------|------------|-----------------|-------\n");

    for (int level = 0; level < n_levels && g_running; level++) {
        uint32_t iters = intensity_levels[level];
        *(uint32_t *)[iter_buf contents] = iters;

        int dispatches = 0;
        uint64_t t_start = mach_absolute_time();
        double deadline_ms = hold_secs * 1000.0;

        while (g_running) {
            double elapsed_ms = mach_to_ms(mach_absolute_time() - t_start);
            if (elapsed_ms >= deadline_ms) break;

            @autoreleasepool {
                id<MTLCommandBuffer> cmd = [queue commandBuffer];
                id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
                [enc setComputePipelineState:pso];
                [enc setBuffer:buf offset:0 atIndex:0];
                [enc setBuffer:iter_buf offset:0 atIndex:1];

                MTLSize grid = MTLSizeMake(n_threads, 1, 1);
                MTLSize tg = MTLSizeMake([pso maxTotalThreadsPerThreadgroup], 1, 1);
                [enc dispatchThreads:grid threadsPerThreadgroup:tg];
                [enc endEncoding];
                [cmd commit];
                [cmd waitUntilCompleted];
                dispatches++;
            }
        }

        double total_ms = mach_to_ms(mach_absolute_time() - t_start);
        double avg_ms = dispatches > 0 ? total_ms / dispatches : 0;
        printf("  %d   | %6u | %10d | %15.3f | done\n",
               level, iters, dispatches, avg_ms);
        fflush(stdout);
    }

    printf("\nSweep complete.\n");

    // Kill powermetrics
    if (pm_pid > 0) {
        kill(pm_pid, SIGTERM);
        waitpid(pm_pid, NULL, 0);
        printf("\npowermetrics log: %s\n", pm_outfile);
    }

    // Parse powermetrics output
    if (use_power && pm_pid > 0) {
        printf("\n=== Parsing powermetrics results ===\n\n");
        fflush(stdout);

        FILE *f = fopen(pm_outfile, "r");
        if (f) {
            char line[4096];
            int sample = 0;
            double last_freq = 0, last_power = 0;
            double max_power = 0, max_freq = 0;

            // Collect per-frequency-bucket residency + power
            printf("Sample | HW Freq MHz | Power mW | P-state residency highlights\n");
            printf("-------|-------------|----------|----------------------------\n");

            while (fgets(line, sizeof(line), f)) {
                if (strstr(line, "GPU HW active frequency:")) {
                    double freq;
                    if (sscanf(line, " GPU HW active frequency: %lf", &freq) == 1) {
                        last_freq = freq;
                    }
                }
                if (strstr(line, "GPU Power:")) {
                    double power;
                    char unit[16];
                    if (sscanf(line, " GPU Power: %lf %s", &power, unit) >= 1) {
                        last_power = power;
                        if (max_power < power) max_power = power;
                        if (max_freq < last_freq) max_freq = last_freq;
                        sample++;
                        if (sample <= 200) {
                            printf("  %3d  |    %7.0f  |  %6.0f  |\n",
                                   sample, last_freq, last_power);
                        }
                    }
                }
            }
            fclose(f);

            printf("\nPeak: %.0f MHz @ %.0f mW\n", max_freq, max_power);
        }
    }

    return 0;
}
