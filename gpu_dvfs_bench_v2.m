// M4 GPU DVFS Voltage Corner Benchmark v2
// Uses duty-cycling + threadgroup count control to hit every P-state.
// The DVFS controller responds to sustained utilization %, not just "busy".
// Key insight: reduce BOTH thread count AND duty cycle to force low P-states.
//
// Build: xcrun clang -framework Metal -framework Foundation -O2 -o gpu_dvfs_bench_v2 gpu_dvfs_bench_v2.m
// Run:   sudo ./gpu_dvfs_bench_v2

#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>
#include <mach/mach_time.h>
#include <pthread.h>

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
    int freq_mhz;
    int voltage_mv;
    const char *name;
} PerfState;

static const PerfState M4_PS[] = {
    {   0,  125, "P0-idle"},
    { 338,  615, "P1"},
    { 618,  645, "P2"},
    { 796,  680, "P3"},
    { 928,  725, "P4"},
    { 952,  780, "P5-A.lo"},
    {1056,  780, "P6-A.hi"},
    {1053,  835, "P7-B.lo"},
    {1170,  835, "P8-B.hi"},
    {1152,  875, "P9-C.lo"},
    {1278,  875, "P10-C.hi"},
    {1204,  905, "P11-D.lo"},
    {1338,  905, "P12-D.hi"},
    {1326,  980, "P13-E.lo"},
    {1470,  980, "P14-E.hi"},
    {1578, 1055, "P15-peak"},
};

static volatile int g_running = 1;
static void sig_handler(int sig) { g_running = 0; }

static double mach_to_us(uint64_t elapsed) {
    static mach_timebase_info_data_t info = {0};
    if (info.denom == 0) mach_timebase_info(&info);
    return (double)elapsed * info.numer / info.denom / 1e3;
}

// powermetrics sampler thread
typedef struct {
    pid_t pid;
    char outfile[256];
    int running;
} PMState;

static void *pm_reader_thread(void *arg) {
    PMState *pm = (PMState *)arg;
    // Just wait for the process
    if (pm->pid > 0) {
        int status;
        waitpid(pm->pid, &status, 0);
    }
    return NULL;
}

static pid_t start_powermetrics(const char *outfile, int interval_ms, int duration_s) {
    int count = (duration_s * 1000) / interval_ms + 10;
    pid_t pid = fork();
    if (pid == 0) {
        char ival[32], cnt[32];
        snprintf(ival, sizeof(ival), "%d", interval_ms);
        snprintf(cnt, sizeof(cnt), "%d", count);
        freopen(outfile, "w", stdout);
        freopen("/dev/null", "w", stderr);
        execlp("powermetrics", "powermetrics",
               "--samplers", "gpu_power",
               "-i", ival, "-n", cnt, NULL);
        _exit(1);
    }
    return pid;
}

int main(int argc, char **argv) {
    signal(SIGINT, sig_handler);

    int hold_secs = 8;
    int pm_interval = 100; // ms

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--hold") == 0 && i+1 < argc) hold_secs = atoi(argv[++i]);
    }

    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) { fprintf(stderr, "No Metal device\n"); return 1; }
    printf("Device: %s\n\n", [[dev name] UTF8String]);

    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:shaderSource options:nil error:&err];
    if (!lib) { fprintf(stderr, "Shader: %s\n", [[err description] UTF8String]); return 1; }
    id<MTLFunction> func = [lib newFunctionWithName:@"stress"];
    id<MTLComputePipelineState> pso = [dev newComputePipelineStateWithFunction:func error:&err];
    id<MTLCommandQueue> queue = [dev newCommandQueue];

    uint32_t max_threads = 1024 * 1024;
    id<MTLBuffer> buf = [dev newBufferWithLength:max_threads * 16 options:MTLResourceStorageModeShared];
    id<MTLBuffer> iter_buf = [dev newBufferWithLength:4 options:MTLResourceStorageModeShared];

    // Strategy: sweep across utilization levels by controlling:
    //   1. Thread count (how much of the GPU is active)
    //   2. Iteration count (how long each dispatch takes)
    //   3. Duty cycle (compute_us / (compute_us + idle_us))
    //
    // DVFS responds to utilization over ~10ms windows.
    // Low utilization → low P-state → lower frequency.

    typedef struct {
        uint32_t threads;
        uint32_t iters;
        uint32_t idle_us;       // microseconds of sleep between dispatches
        const char *label;
    } Level;

    // Carefully tuned levels to explore all 15 P-states
    Level levels[] = {
        // Ultra-low: minimal work, long idle → should hit P1-P2
        {    1024,    1,  5000, "ultra-low-1"},
        {    1024,    1,  2000, "ultra-low-2"},
        {    4096,    1,  2000, "ultra-low-3"},
        // Low: small grid, short work → P2-P4
        {    4096,    4,  1000, "low-1"},
        {   16384,    4,  1000, "low-2"},
        {   16384,    8,   500, "low-3"},
        // Medium-low: growing grid → P4-P6
        {   32768,   16,   500, "med-low-1"},
        {   65536,   16,   200, "med-low-2"},
        {   65536,   32,   200, "med-1"},
        // Medium: decent load → P6-P10
        {  131072,   32,   100, "med-2"},
        {  131072,   64,   100, "med-3"},
        {  262144,   64,    50, "med-hi-1"},
        // Medium-high: heavy → P10-P13
        {  262144,  128,    50, "med-hi-2"},
        {  524288,  128,     0, "med-hi-3"},
        {  524288,  256,     0, "high-1"},
        // High: full grid → P13-P15
        { 1048576,  256,     0, "high-2"},
        { 1048576,  512,     0, "high-3"},
        { 1048576, 1024,     0, "very-high"},
        { 1048576, 4096,     0, "max-1"},
        { 1048576,16384,     0, "max-2"},
        { 1048576,65536,     0, "peak"},
    };
    int n_levels = sizeof(levels) / sizeof(levels[0]);

    // Print DVFS table
    printf("=== M4 GPU DVFS Table (device tree perf-states) ===\n");
    printf("%-12s %6s %8s %s\n", "P-state", "MHz", "mV", "Corner");
    for (int i = 0; i < 16; i++) {
        printf("  %-10s %5d  %6d   %s\n",
               M4_PS[i].name, M4_PS[i].freq_mhz, M4_PS[i].voltage_mv,
               (i >= 5 && i <= 14 && i % 2 == 0) ? "<-- same V as above" : "");
    }
    printf("\n");

    // Start powermetrics
    char pm_out[256];
    snprintf(pm_out, sizeof(pm_out), "/tmp/gpu_dvfs_v2_%d.log", getpid());
    int total_dur = n_levels * hold_secs + 30;
    pid_t pm_pid = start_powermetrics(pm_out, pm_interval, total_dur);
    printf("powermetrics → %s (pid %d)\n\n", pm_out, pm_pid);
    usleep(1000000); // 1s settle

    printf("=== Sweep: %d levels × %ds ===\n\n", n_levels, hold_secs);
    printf("%-14s %8s %6s %7s %8s\n",
           "Level", "Threads", "Iters", "IdleUs", "Dispatch");
    printf("%.60s\n", "------------------------------------------------------------");

    for (int L = 0; L < n_levels && g_running; L++) {
        Level *lv = &levels[L];
        uint32_t threads = lv->threads > max_threads ? max_threads : lv->threads;
        *(uint32_t *)[iter_buf contents] = lv->iters;

        int dispatches = 0;
        uint64_t t0 = mach_absolute_time();
        double deadline_us = hold_secs * 1e6;

        while (g_running) {
            double el = mach_to_us(mach_absolute_time() - t0);
            if (el >= deadline_us) break;

            @autoreleasepool {
                id<MTLCommandBuffer> cmd = [queue commandBuffer];
                id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
                [enc setComputePipelineState:pso];
                [enc setBuffer:buf offset:0 atIndex:0];
                [enc setBuffer:iter_buf offset:0 atIndex:1];
                MTLSize grid = MTLSizeMake(threads, 1, 1);
                MTLSize tg = MTLSizeMake(MIN(threads, [pso maxTotalThreadsPerThreadgroup]), 1, 1);
                [enc dispatchThreads:grid threadsPerThreadgroup:tg];
                [enc endEncoding];
                [cmd commit];
                [cmd waitUntilCompleted];
                dispatches++;
            }

            if (lv->idle_us > 0) usleep(lv->idle_us);
        }

        double total_us = mach_to_us(mach_absolute_time() - t0);
        printf("%-14s %8u %6u %7u %8d (%.1f ms total)\n",
               lv->label, threads, lv->iters, lv->idle_us,
               dispatches, total_us / 1000.0);
        fflush(stdout);

        // Brief idle between levels for DVFS to settle
        usleep(500000);
    }

    printf("\nSweep done.\n");

    // Stop powermetrics
    if (pm_pid > 0) {
        kill(pm_pid, SIGTERM);
        int status;
        waitpid(pm_pid, &status, 0);
    }

    // Parse inline — extract per-sample freq + power + residency
    printf("\n=== Parsing %s ===\n\n", pm_out);
    fflush(stdout);

    FILE *f = fopen(pm_out, "r");
    if (!f) { printf("Cannot open %s\n", pm_out); return 1; }

    char line[8192];
    int sample = 0;
    double cur_freq = 0;
    int bucket_freqs[16] = {0};
    double bucket_powers[16][1000];
    int bucket_counts[16] = {0};
    int freq_map[16] = {0, 338, 618, 796, 928, 952, 1056, 1053, 1170, 1152, 1278, 1204, 1338, 1326, 1470, 1578};

    // Track which P-state has the most residency
    int dom_pstate = -1;
    double dom_pct = 0;

    while (fgets(line, sizeof(line), f)) {
        // Parse HW active residency line for per-P-state residency
        char *res = strstr(line, "GPU HW active residency:");
        if (res) {
            dom_pstate = -1;
            dom_pct = 0;
            // Parse each "XXX MHz: YY.Y%"
            char *p = strchr(res, '(');
            if (p) {
                int freq;
                double pct;
                while (p && *p) {
                    if (sscanf(p, "%d MHz: %lf%%", &freq, &pct) == 2 ||
                        sscanf(p, " %d MHz: %lf%%", &freq, &pct) == 2) {
                        if (pct > dom_pct) {
                            dom_pct = pct;
                            // Map freq to P-state index
                            dom_pstate = -1;
                            for (int i = 0; i < 16; i++) {
                                if (freq_map[i] == freq) { dom_pstate = i; break; }
                            }
                        }
                    }
                    p = strchr(p + 1, ' ');
                    while (p && *p == ' ') p++;
                    // Skip to next MHz entry
                    if (p) {
                        char *next = strstr(p, "MHz:");
                        if (next && next > p) p = next - 5;
                        else break;
                    }
                }
            }
        }

        char *hw = strstr(line, "GPU HW active frequency:");
        if (hw) {
            sscanf(hw, "GPU HW active frequency: %lf", &cur_freq);
        }

        if (strstr(line, "GPU Power:")) {
            double power;
            char unit[16] = {0};
            if (sscanf(line, " GPU Power: %lf %s", &power, unit) >= 1) {
                if (unit[0] == 'W' && unit[1] == 0) power *= 1000;
                sample++;

                // Map to nearest P-state by frequency
                int nearest = 0;
                int min_diff = 999999;
                for (int i = 1; i < 16; i++) {
                    int d = abs((int)cur_freq - freq_map[i]);
                    if (d < min_diff) { min_diff = d; nearest = i; }
                }

                // Use dominant P-state if available and > 30%
                int ps = (dom_pstate >= 0 && dom_pct > 30) ? dom_pstate : nearest;
                if (ps >= 0 && ps < 16 && bucket_counts[ps] < 1000) {
                    bucket_powers[ps][bucket_counts[ps]++] = power;
                }

                if (sample <= 10 || sample % 25 == 0) {
                    printf("  #%3d  freq=%4.0f MHz  power=%6.0f mW  dom_ps=P%d(%.0f%%)\n",
                           sample, cur_freq, power,
                           dom_pstate >= 0 ? dom_pstate : nearest,
                           dom_pct);
                }
            }
        }
    }
    fclose(f);

    printf("\nTotal samples: %d\n", sample);

    // Per-P-state power summary
    printf("\n=== Power by P-state (where observed) ===\n\n");
    printf("%-12s %6s %6s %8s %8s %8s %8s\n",
           "P-state", "MHz", "mV", "Samples", "Avg mW", "Min mW", "Max mW");
    printf("%.70s\n", "----------------------------------------------------------------------");

    for (int i = 0; i < 16; i++) {
        if (bucket_counts[i] == 0) continue;
        double sum = 0, mn = 1e9, mx = 0;
        for (int j = 0; j < bucket_counts[i]; j++) {
            double p = bucket_powers[i][j];
            sum += p;
            if (p < mn) mn = p;
            if (p > mx) mx = p;
        }
        printf("  %-10s %5d  %5d  %7d  %7.0f  %7.0f  %7.0f\n",
               M4_PS[i].name, M4_PS[i].freq_mhz, M4_PS[i].voltage_mv,
               bucket_counts[i], sum / bucket_counts[i], mn, mx);
    }

    // Voltage corner analysis
    printf("\n=== Voltage Corner Analysis ===\n\n");
    printf("Same-voltage pairs — power difference shows frequency scaling cost:\n\n");
    int pairs[][2] = {{5,6},{7,8},{9,10},{11,12},{13,14}};
    const char *corner_names[] = {"A (780mV)", "B (835mV)", "C (875mV)", "D (905mV)", "E (980mV)"};
    for (int p = 0; p < 5; p++) {
        int lo = pairs[p][0], hi = pairs[p][1];
        if (bucket_counts[lo] > 0 && bucket_counts[hi] > 0) {
            double avg_lo = 0, avg_hi = 0;
            for (int j = 0; j < bucket_counts[lo]; j++) avg_lo += bucket_powers[lo][j];
            avg_lo /= bucket_counts[lo];
            for (int j = 0; j < bucket_counts[hi]; j++) avg_hi += bucket_powers[hi][j];
            avg_hi /= bucket_counts[hi];
            printf("  Corner %s: %s(%dMHz)=%.0f mW → %s(%dMHz)=%.0f mW  Δ=%.0f mW (+%.1f%%)\n",
                   corner_names[p],
                   M4_PS[lo].name, M4_PS[lo].freq_mhz, avg_lo,
                   M4_PS[hi].name, M4_PS[hi].freq_mhz, avg_hi,
                   avg_hi - avg_lo, (avg_hi - avg_lo) / avg_lo * 100);
        } else {
            printf("  Corner %s: insufficient samples (lo=%d, hi=%d)\n",
                   corner_names[p], bucket_counts[lo], bucket_counts[hi]);
        }
    }

    printf("\nDone. Raw log: %s\n", pm_out);
    return 0;
}
