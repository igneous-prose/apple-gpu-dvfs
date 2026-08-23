// gpu_freq_ctl — Control Apple Silicon GPU frequency via CLPC power budget
//
// Controls DVFS by writing the AppleCLPC power budget properties.
// Lowering the package power cap forces the CLPC to throttle GPU frequency.
//
// Build:
//   xcrun clang -framework IOKit -framework Foundation -framework Metal -O2 \
//     -o gpu_freq_ctl gpu_freq_ctl.m
//
// Usage:
//   sudo ./gpu_freq_ctl status          Show current CLPC state + GPU frequency
//   sudo ./gpu_freq_ctl cap <watts>     Cap package power (forces lower P-state)
//   sudo ./gpu_freq_ctl uncap           Restore original CLPC values
//   sudo ./gpu_freq_ctl sweep           Sweep power caps and measure GPU freq at each
//   sudo ./gpu_freq_ctl table           Print the DVFS P-state table from device tree

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <Metal/Metal.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>

#pragma mark - CLPC interface

typedef struct {
    int64_t pkg_avg_max_power;
    int64_t pkg_lowpeak_max_power;
    int64_t pkg_power_zone_target_0;
    int64_t pkg_power_zone_target_offset_0;
    int64_t pkg_power_split_gpu_fraction;
    int64_t pkg_power_split_cpu_fraction;
    int64_t pkg_power_split_ane_fraction;
    int64_t carplay_power_limit;
    int64_t pkg_low_power_target;
    int64_t pkg_avg_therm_power_target;
    int64_t pkg_avg_limiter_ki;
    int64_t pkg_avg_limiter_kp;
    int64_t pkg_lowpeak_limiter_ki;
    int64_t pkg_lowpeak_limiter_kp;
    int64_t cpu_avg_limiter_ki;
    int64_t cpu_avg_limiter_kp;
    int64_t cpu_lowpeak_limiter_ki;
    int64_t cpu_lowpeak_limiter_kp;
    int64_t cpu_rot_pwr_engage_thresh;
    int64_t cpu_rot_pwr_disengage_thresh;
} CLPCState;

static io_service_t g_clpc = 0;

static io_service_t get_clpc(void) {
    if (g_clpc) return g_clpc;
    io_iterator_t iter;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault,
        IOServiceMatching("AppleCLPC"), &iter);
    if (kr != KERN_SUCCESS) return 0;
    g_clpc = IOIteratorNext(iter);
    IOObjectRelease(iter);
    return g_clpc;
}

static kern_return_t clpc_set(const char *key, int64_t value) {
    io_service_t svc = get_clpc();
    if (!svc) return -1;
    CFStringRef cfKey = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFNumberRef cfVal = CFNumberCreate(NULL, kCFNumberSInt64Type, &value);
    CFMutableDictionaryRef dict = CFDictionaryCreateMutable(
        NULL, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(dict, cfKey, cfVal);
    kern_return_t kr = IORegistryEntrySetCFProperties(svc, dict);
    CFRelease(dict); CFRelease(cfVal); CFRelease(cfKey);
    return kr;
}

static int64_t clpc_get(const char *key) {
    io_service_t svc = get_clpc();
    if (!svc) return 0;
    CFStringRef cfKey = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFTypeRef val = IORegistryEntryCreateCFProperty(svc, cfKey, NULL, 0);
    CFRelease(cfKey);
    if (!val) return 0;
    int64_t result = 0;
    if (CFGetTypeID(val) == CFNumberGetTypeID())
        CFNumberGetValue((CFNumberRef)val, kCFNumberSInt64Type, &result);
    CFRelease(val);
    return result;
}

static CLPCState clpc_read_state(void) {
    CLPCState s;
    s.pkg_avg_max_power = clpc_get("~pkg-avg-max-power");
    s.pkg_lowpeak_max_power = clpc_get("~pkg-lowpeak-max-power");
    s.pkg_power_zone_target_0 = clpc_get("~pkg-power-zone-target-0");
    s.pkg_power_zone_target_offset_0 = clpc_get("~pkg-power-zone-target-offset-0");
    s.pkg_power_split_gpu_fraction = clpc_get("~pkg-power-split-gpu-fraction");
    s.pkg_power_split_cpu_fraction = clpc_get("~pkg-power-split-cpu-fraction");
    s.pkg_power_split_ane_fraction = clpc_get("~pkg-power-split-ane-fraction");
    s.carplay_power_limit = clpc_get("~carplay-power-limit");
    s.pkg_low_power_target = clpc_get("`pkg-low-power-target");
    s.pkg_avg_therm_power_target = clpc_get("`pkg-avg-therm-power-target");
    s.pkg_avg_limiter_ki = clpc_get("`pkg-avg-limiter-ki");
    s.pkg_avg_limiter_kp = clpc_get("`pkg-avg-limiter-kp");
    s.pkg_lowpeak_limiter_ki = clpc_get("`pkg-lowpeak-limiter-ki");
    s.pkg_lowpeak_limiter_kp = clpc_get("`pkg-lowpeak-limiter-kp");
    s.cpu_avg_limiter_ki = clpc_get("`cpu-avg-limiter-ki");
    s.cpu_avg_limiter_kp = clpc_get("`cpu-avg-limiter-kp");
    s.cpu_lowpeak_limiter_ki = clpc_get("`cpu-lowpeak-limiter-ki");
    s.cpu_lowpeak_limiter_kp = clpc_get("`cpu-lowpeak-limiter-kp");
    s.cpu_rot_pwr_engage_thresh = clpc_get("~cpu-rot-pwr-engage-thresh");
    s.cpu_rot_pwr_disengage_thresh = clpc_get("~cpu-rot-pwr-disengage-thresh");
    return s;
}

static void clpc_write_state(const CLPCState *s) {
    clpc_set("~pkg-avg-max-power", s->pkg_avg_max_power);
    clpc_set("~pkg-lowpeak-max-power", s->pkg_lowpeak_max_power);
    clpc_set("~pkg-power-zone-target-0", s->pkg_power_zone_target_0);
    clpc_set("~pkg-power-zone-target-offset-0", s->pkg_power_zone_target_offset_0);
    clpc_set("~pkg-power-split-gpu-fraction", s->pkg_power_split_gpu_fraction);
    clpc_set("~pkg-power-split-cpu-fraction", s->pkg_power_split_cpu_fraction);
    clpc_set("~pkg-power-split-ane-fraction", s->pkg_power_split_ane_fraction);
    clpc_set("~carplay-power-limit", s->carplay_power_limit);
    clpc_set("`pkg-low-power-target", s->pkg_low_power_target);
    clpc_set("`pkg-avg-therm-power-target", s->pkg_avg_therm_power_target);
    clpc_set("`pkg-avg-limiter-ki", s->pkg_avg_limiter_ki);
    clpc_set("`pkg-avg-limiter-kp", s->pkg_avg_limiter_kp);
    clpc_set("`pkg-lowpeak-limiter-ki", s->pkg_lowpeak_limiter_ki);
    clpc_set("`pkg-lowpeak-limiter-kp", s->pkg_lowpeak_limiter_kp);
    clpc_set("`cpu-avg-limiter-ki", s->cpu_avg_limiter_ki);
    clpc_set("`cpu-avg-limiter-kp", s->cpu_avg_limiter_kp);
    clpc_set("`cpu-lowpeak-limiter-ki", s->cpu_lowpeak_limiter_ki);
    clpc_set("`cpu-lowpeak-limiter-kp", s->cpu_lowpeak_limiter_kp);
    clpc_set("~cpu-rot-pwr-engage-thresh", s->cpu_rot_pwr_engage_thresh);
    clpc_set("~cpu-rot-pwr-disengage-thresh", s->cpu_rot_pwr_disengage_thresh);
}

static const char *STATEFILE = "/tmp/.gpu_freq_ctl_saved_state";

static void save_state(const CLPCState *s) {
    FILE *f = fopen(STATEFILE, "wb");
    if (f) { fwrite(s, sizeof(CLPCState), 1, f); fclose(f); }
}

static int load_state(CLPCState *s) {
    FILE *f = fopen(STATEFILE, "rb");
    if (!f) return 0;
    int ok = fread(s, sizeof(CLPCState), 1, f) == 1;
    fclose(f);
    return ok;
}

#pragma mark - GPU measurement

static NSString *matmulShader = @
"#include <metal_stdlib>\nusing namespace metal;\n"
"kernel void mm(device const float *A[[buffer(0)]],device const float *B[[buffer(1)]],"
"device float *C[[buffer(2)]],constant uint &N[[buffer(3)]],"
"uint2 g[[thread_position_in_grid]],uint2 l[[thread_position_in_threadgroup]]){"
"uint r=g.y,c=g.x;if(r>=N||c>=N)return;"
"threadgroup float As[16][16],Bs[16][16];float a=0;"
"for(uint t=0;t<(N+15)/16;t++){uint ac=t*16+l.x,br=t*16+l.y;"
"As[l.y][l.x]=(r<N&&ac<N)?A[r*N+ac]:0;Bs[l.y][l.x]=(br<N&&c<N)?B[br*N+c]:0;"
"threadgroup_barrier(mem_flags::mem_threadgroup);"
"for(uint i=0;i<16;i++)a=fma(As[l.y][i],Bs[i][l.x],a);"
"threadgroup_barrier(mem_flags::mem_threadgroup);}C[r*N+c]=a;}";

static double measure_gflops(void) {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) return -1;
    NSError *err;
    id<MTLLibrary> lib = [dev newLibraryWithSource:matmulShader options:nil error:&err];
    if (!lib) return -1;
    id<MTLComputePipelineState> pso = [dev newComputePipelineStateWithFunction:
        [lib newFunctionWithName:@"mm"] error:&err];
    id<MTLCommandQueue> queue = [dev newCommandQueue];

    uint32_t N = 2048;
    id<MTLBuffer> A = [dev newBufferWithLength:N*N*4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> B = [dev newBufferWithLength:N*N*4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> C = [dev newBufferWithLength:N*N*4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> Nb = [dev newBufferWithBytes:&N length:4 options:MTLResourceStorageModeShared];

    double best = 1e9;
    for (int r = 0; r < 5; r++) {
        @autoreleasepool {
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
            [enc setComputePipelineState:pso];
            [enc setBuffer:A offset:0 atIndex:0];
            [enc setBuffer:B offset:0 atIndex:1];
            [enc setBuffer:C offset:0 atIndex:2];
            [enc setBuffer:Nb offset:0 atIndex:3];
            [enc dispatchThreads:MTLSizeMake(N,N,1) threadsPerThreadgroup:MTLSizeMake(16,16,1)];
            [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
            double ms = ([cb GPUEndTime] - [cb GPUStartTime]) * 1000.0;
            if (ms < best) best = ms;
        }
    }
    return 2.0 * N * N * N / (best * 1e6);
}

#pragma mark - DVFS table

typedef struct { uint32_t freq_mhz; uint32_t voltage_mv; uint32_t sram_mv; } PState;

static int read_dvfs_table(PState *out, int max_entries) {
    io_iterator_t iter;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault,
        IOServiceNameMatching("sgx"), &iter);
    if (kr != KERN_SUCCESS) return 0;

    io_service_t svc = IOIteratorNext(iter);
    IOObjectRelease(iter);
    if (!svc) return 0;

    int count = 0;
    CFTypeRef ps_ref = IORegistryEntryCreateCFProperty(svc,
        CFSTR("perf-states"), NULL, 0);
    CFTypeRef sram_ref = IORegistryEntryCreateCFProperty(svc,
        CFSTR("perf-states-sram"), NULL, 0);
    CFTypeRef cnt_ref = IORegistryEntryCreateCFProperty(svc,
        CFSTR("perf-state-count"), NULL, 0);

    if (ps_ref && CFGetTypeID(ps_ref) == CFDataGetTypeID()) {
        CFDataRef ps_data = (CFDataRef)ps_ref;
        CFDataRef sram_data = sram_ref && CFGetTypeID(sram_ref) == CFDataGetTypeID()
                            ? (CFDataRef)sram_ref : NULL;
        CFIndex len = CFDataGetLength(ps_data);
        const uint8_t *bytes = CFDataGetBytePtr(ps_data);
        const uint8_t *sram_bytes = sram_data ? CFDataGetBytePtr(sram_data) : NULL;

        count = (int)(len / 8);
        if (count > max_entries) count = max_entries;

        for (int i = 0; i < count; i++) {
            uint32_t freq, mv, smv = 0;
            memcpy(&freq, bytes + i * 8, 4);
            memcpy(&mv, bytes + i * 8 + 4, 4);
            if (sram_bytes) memcpy(&smv, sram_bytes + i * 8 + 4, 4);
            out[i].freq_mhz = freq / 1000000;
            out[i].voltage_mv = mv;
            out[i].sram_mv = smv;
        }
    }

    if (ps_ref) CFRelease(ps_ref);
    if (sram_ref) CFRelease(sram_ref);
    if (cnt_ref) CFRelease(cnt_ref);
    IOObjectRelease(svc);
    return count;
}

#pragma mark - Commands

static void cmd_status(void) {
    CLPCState s = clpc_read_state();
    printf("CLPC Power Budget:\n");
    printf("  pkg-avg-max-power:      %.2f W\n", s.pkg_avg_max_power / 1048576.0);
    printf("  pkg-lowpeak-max-power:  %.2f W\n", s.pkg_lowpeak_max_power / 1048576.0);
    printf("  power-zone-target-0:    %.2f W\n", s.pkg_power_zone_target_0 / 1048576.0);
    printf("  gpu-fraction:           %.0f%%\n", s.pkg_power_split_gpu_fraction / 655.36);
    printf("  pkg-low-power-target:   %lld %s\n", s.pkg_low_power_target,
           s.pkg_low_power_target < 0 ? "(disabled)" : "");
    printf("\n");

    int saved = access(STATEFILE, F_OK) == 0;
    printf("Saved state: %s\n\n", saved ? STATEFILE : "(none)");

    printf("GPU matmul (2048x2048, best of 5):\n");
    double gf = measure_gflops();
    printf("  %.1f GFLOPS\n", gf);
    if (gf > 500) printf("  → GPU at peak (P15, ~1578 MHz)\n");
    else if (gf > 200) printf("  → GPU partially throttled\n");
    else printf("  → GPU heavily throttled (low P-state)\n");
}

static void cmd_cap(double watts) {
    CLPCState orig = clpc_read_state();
    save_state(&orig);
    printf("Saved original state to %s\n", STATEFILE);

    int64_t raw = (int64_t)(watts * 1048576.0);
    printf("Setting package power cap to %.1f W (raw=%lld)\n", watts, raw);

    clpc_set("~pkg-avg-max-power", raw);
    clpc_set("~pkg-lowpeak-max-power", raw);
    clpc_set("`pkg-low-power-target", raw);
    if (watts < 5.0) {
        clpc_set("~pkg-power-zone-target-0", raw * 2);
    }

    printf("Burning in GPU for 10s to trigger CLPC throttle...\n");
    fflush(stdout);

    // Run sustained GPU compute so the CLPC observes power draw above the new cap
    // and actually throttles. Without this, the CLPC hasn't seen the overshoot.
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    NSError *err;
    id<MTLLibrary> lib = [dev newLibraryWithSource:matmulShader options:nil error:&err];
    id<MTLComputePipelineState> pso = [dev newComputePipelineStateWithFunction:
        [lib newFunctionWithName:@"mm"] error:&err];
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    uint32_t N = 2048;
    id<MTLBuffer> A = [dev newBufferWithLength:N*N*4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> B = [dev newBufferWithLength:N*N*4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> C = [dev newBufferWithLength:N*N*4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> Nb = [dev newBufferWithBytes:&N length:4 options:MTLResourceStorageModeShared];

    uint64_t start = mach_absolute_time();
    mach_timebase_info_data_t tbi;
    mach_timebase_info(&tbi);
    int dispatches = 0;

    while (1) {
        uint64_t elapsed_ns = (mach_absolute_time() - start) * tbi.numer / tbi.denom;
        if (elapsed_ns > 10000000000ULL) break; // 10s

        @autoreleasepool {
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
            [enc setComputePipelineState:pso];
            [enc setBuffer:A offset:0 atIndex:0]; [enc setBuffer:B offset:0 atIndex:1];
            [enc setBuffer:C offset:0 atIndex:2]; [enc setBuffer:Nb offset:0 atIndex:3];
            [enc dispatchThreads:MTLSizeMake(N,N,1) threadsPerThreadgroup:MTLSizeMake(16,16,1)];
            [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
            dispatches++;
        }
    }
    printf("  %d dispatches in 10s\n", dispatches);

    double gf = measure_gflops();
    printf("GPU: %.1f GFLOPS\n", gf);
    if (gf < 500) printf("  → Throttle confirmed\n");
    else printf("  → CLPC may need more time\n");
    printf("\nTo restore: sudo ./gpu_freq_ctl uncap\n");
}

static void cmd_uncap(void) {
    CLPCState saved;
    if (!load_state(&saved)) {
        printf("No saved state at %s\n", STATEFILE);
        printf("Attempting factory defaults (M4)...\n");
        saved.pkg_avg_max_power = 4915200;
        saved.pkg_lowpeak_max_power = 4915200;
        saved.pkg_power_zone_target_0 = 7536640;
        saved.pkg_power_zone_target_offset_0 = 0;
        saved.pkg_power_split_gpu_fraction = 32768;
        saved.pkg_power_split_cpu_fraction = 32768;
        saved.pkg_power_split_ane_fraction = 0;
        saved.carplay_power_limit = 16711680;
        saved.pkg_low_power_target = -16777216;
        saved.pkg_avg_therm_power_target = -16777216;
        saved.pkg_avg_limiter_ki = 2466;
        saved.pkg_avg_limiter_kp = 72645;
        saved.pkg_lowpeak_limiter_ki = 29025;
        saved.pkg_lowpeak_limiter_kp = 261725;
        saved.cpu_avg_limiter_ki = 20132;
        saved.cpu_avg_limiter_kp = 671088;
        saved.cpu_lowpeak_limiter_ki = 134217;
        saved.cpu_lowpeak_limiter_kp = 33554;
        saved.cpu_rot_pwr_engage_thresh = 229376;
        saved.cpu_rot_pwr_disengage_thresh = 163840;
    } else {
        printf("Restoring saved state from %s\n", STATEFILE);
    }

    clpc_write_state(&saved);
    printf("CLPC properties restored.\n");
    unlink(STATEFILE);

    printf("Waiting 5s for CLPC to settle...\n");
    sleep(5);

    double gf = measure_gflops();
    printf("GPU: %.1f GFLOPS", gf);
    if (gf > 500) printf(" (recovered)\n");
    else printf(" (still throttled — try again or sleep/wake)\n");
}

static void cmd_sweep(void) {
    CLPCState orig = clpc_read_state();
    save_state(&orig);

    double caps[] = {1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 5.0, 6.0, 8.0, 10.0, 15.0};
    int n_caps = sizeof(caps) / sizeof(caps[0]);

    printf("Power cap sweep (measuring GFLOPS at each level):\n\n");
    printf("  Cap (W)   GFLOPS   Ratio\n");
    printf("  -------   ------   -----\n");

    double peak_gf = 0;

    for (int i = n_caps - 1; i >= 0; i--) {
        int64_t raw = (int64_t)(caps[i] * 1048576.0);
        // Restore original state first so each level starts clean
        clpc_write_state(&orig);
        sleep(3);
        // Then apply the cap
        clpc_set("~pkg-avg-max-power", raw);
        clpc_set("~pkg-lowpeak-max-power", raw);
        clpc_set("`pkg-low-power-target", raw);
        if (caps[i] < 5.0)
            clpc_set("~pkg-power-zone-target-0", raw * 2);

        // Burn in to trigger CLPC
        for (int b = 0; b < 3; b++) measure_gflops();
        sleep(2);
        double gf = measure_gflops();
        if (gf > peak_gf) peak_gf = gf;
        printf("  %5.1f     %6.1f   %5.1f%%\n", caps[i], gf,
               peak_gf > 0 ? gf / peak_gf * 100 : 100.0);
        fflush(stdout);
    }

    printf("\nRestoring original state...\n");
    clpc_write_state(&orig);
    sleep(5);
    double gf = measure_gflops();
    printf("Restored: %.1f GFLOPS\n", gf);
    unlink(STATEFILE);
}

static void cmd_table(void) {
    PState ps[32];
    int count = read_dvfs_table(ps, 32);
    if (count == 0) {
        printf("Could not read DVFS table from device tree\n");
        return;
    }

    printf("GPU DVFS Table (%d P-states from device tree):\n\n", count);
    printf("  P-state   Freq MHz   GPU mV   SRAM mV   Corner\n");
    printf("  -------   --------   ------   -------   ------\n");

    for (int i = 0; i < count; i++) {
        const char *corner = "";
        if (i == 0) corner = "idle";
        else if (i == 3) corner = "base";
        else if (i == count - 1) corner = "peak";
        else if (i >= 5 && i <= 14 && i % 2 == 0)
            corner = "same V as above";

        printf("  P%-2d       %5u      %5u    %5u     %s\n",
               i, ps[i].freq_mhz, ps[i].voltage_mv, ps[i].sram_mv, corner);
    }
}

#pragma mark - Main

int main(int argc, char **argv) {
    if (argc < 2) {
        printf("gpu_freq_ctl — Control Apple Silicon GPU frequency via CLPC\n\n");
        printf("Usage:\n");
        printf("  sudo ./gpu_freq_ctl status       Show CLPC state + GPU speed\n");
        printf("  sudo ./gpu_freq_ctl cap <watts>   Cap package power → throttle GPU\n");
        printf("  sudo ./gpu_freq_ctl uncap         Restore original CLPC values\n");
        printf("  sudo ./gpu_freq_ctl sweep         Sweep power caps, measure GFLOPS\n");
        printf("  sudo ./gpu_freq_ctl table         Print DVFS P-state table\n");
        return 0;
    }

    if (geteuid() != 0 && strcmp(argv[1], "table") != 0) {
        fprintf(stderr, "Need root (sudo) for CLPC control\n");
        return 1;
    }

    if (!get_clpc() && strcmp(argv[1], "table") != 0) {
        fprintf(stderr, "AppleCLPC not found\n");
        return 1;
    }

    if (strcmp(argv[1], "status") == 0) cmd_status();
    else if (strcmp(argv[1], "cap") == 0 && argc > 2) cmd_cap(atof(argv[2]));
    else if (strcmp(argv[1], "uncap") == 0) cmd_uncap();
    else if (strcmp(argv[1], "sweep") == 0) cmd_sweep();
    else if (strcmp(argv[1], "table") == 0) cmd_table();
    else { fprintf(stderr, "Unknown command: %s\n", argv[1]); return 1; }

    return 0;
}
