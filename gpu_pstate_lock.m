// gpu_pstate_lock — attempt to lock M4 GPU to a specific P-state
// Tries multiple approaches:
// 1. IOServiceSetProperties on AGXAcceleratorG16G
// 2. IOKit user client external method
// 3. MMIO register write (Asahi-style, needs SIP off)
//
// Build: xcrun clang -framework IOKit -framework Foundation -O2 -o gpu_pstate_lock gpu_pstate_lock.m
// Run:   sudo ./gpu_pstate_lock <pstate>     (0-15)
//        sudo ./gpu_pstate_lock --scan       (try all known property names)
//        sudo ./gpu_pstate_lock --monitor    (watch frequency transitions)

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char *PSTATE_NAMES[] = {
    "P0 (idle, 0 MHz, 125 mV)",
    "P1 (338 MHz, 615 mV)",
    "P2 (618 MHz, 645 mV)",
    "P3 (796 MHz, 680 mV) [base]",
    "P4 (928 MHz, 725 mV)",
    "P5 (952 MHz, 780 mV) [A·lo]",
    "P6 (1056 MHz, 780 mV) [A·hi]",
    "P7 (1053 MHz, 835 mV) [B·lo]",
    "P8 (1170 MHz, 835 mV) [B·hi]",
    "P9 (1152 MHz, 875 mV) [C·lo]",
    "P10 (1278 MHz, 875 mV) [C·hi]",
    "P11 (1204 MHz, 905 mV) [D·lo]",
    "P12 (1338 MHz, 905 mV) [D·hi]",
    "P13 (1326 MHz, 980 mV) [E·lo]",
    "P14 (1470 MHz, 980 mV) [E·hi]",
    "P15 (1578 MHz, 1055 mV) [peak]",
};

static io_service_t find_agx(void) {
    io_iterator_t iter;
    kern_return_t kr = IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceMatching("AGXAcceleratorG16G"),
        &iter);
    if (kr != KERN_SUCCESS) return 0;
    io_service_t svc = IOIteratorNext(iter);
    IOObjectRelease(iter);
    return svc;
}

static kern_return_t try_set_property(io_service_t svc, const char *key, int value) {
    CFStringRef cfKey = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFNumberRef cfVal = CFNumberCreate(NULL, kCFNumberIntType, &value);
    CFMutableDictionaryRef dict = CFDictionaryCreateMutable(
        NULL, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(dict, cfKey, cfVal);

    kern_return_t kr = IORegistryEntrySetCFProperties(svc, dict);

    CFRelease(dict);
    CFRelease(cfVal);
    CFRelease(cfKey);
    return kr;
}

static void scan_properties(io_service_t svc, int target_pstate) {
    // Try all known/guessed property names that might control P-state
    const char *candidates[] = {
        "PerformanceStateCap",
        "PerfStateCap",
        "gpu-perf-state-cap",
        "GPUPerfStateCap",
        "perf-level",
        "PerfLevel",
        "gpu-perf-level",
        "GPUPerfLevel",
        "DesiredPerfState",
        "TargetPerfState",
        "RequestedPerfState",
        "gpu-max-pstate",
        "GPUMaxPState",
        "gpu-min-pstate",
        "GPUMinPState",
        "GPUPowerZoneFilter",
        "gpu-power-cap",
        "PerformanceCap",
        "MaxPerfState",
        "MinPerfState",
        "ForcePerformanceState",
        "ForcePState",
        "gpu-force-pstate",
        "GPUForcePState",
        "perf-state-override",
        "agx-perf-state",
        "agx-force-pstate",
        NULL
    };

    printf("Scanning AGX property names with target P-state = %d...\n\n", target_pstate);
    for (int i = 0; candidates[i]; i++) {
        kern_return_t kr = try_set_property(svc, candidates[i], target_pstate);
        const char *status;
        switch (kr) {
            case KERN_SUCCESS: status = "ACCEPTED"; break;
            case 0xe00002c2: status = "unsupported"; break; // kIOReturnUnsupported
            case 0xe00002bc: status = "not permitted"; break; // kIOReturnNotPermitted
            case 0xe00002be: status = "bad argument"; break; // kIOReturnBadArgument
            case 0xe00002ed: status = "not writable"; break; // kIOReturnNotWritable
            default: status = "failed"; break;
        }
        printf("  %-30s → %s (0x%x)\n", candidates[i], status, kr);
    }
}

int main(int argc, char **argv) {
    if (argc < 2) {
        printf("Usage:\n");
        printf("  sudo %s <pstate>     Lock GPU to P-state (0-15)\n", argv[0]);
        printf("  sudo %s --scan       Try all known property names\n", argv[0]);
        printf("  sudo %s --monitor    Watch frequency in real-time\n", argv[0]);
        printf("  sudo %s --unlock     Remove P-state lock\n", argv[0]);
        printf("\nP-states:\n");
        for (int i = 0; i < 16; i++) {
            printf("  %2d: %s\n", i, PSTATE_NAMES[i]);
        }
        return 0;
    }

    if (geteuid() != 0) {
        fprintf(stderr, "Need root (sudo)\n");
        return 1;
    }

    io_service_t svc = find_agx();
    if (!svc) {
        fprintf(stderr, "AGXAcceleratorG16G not found\n");
        return 1;
    }
    printf("Found AGXAcceleratorG16G\n\n");

    if (strcmp(argv[1], "--scan") == 0) {
        int target = argc > 2 ? atoi(argv[2]) : 3;
        scan_properties(svc, target);
    }
    else if (strcmp(argv[1], "--monitor") == 0) {
        printf("Monitoring GPU P-state (Ctrl-C to stop)...\n");
        printf("(Run a compute workload in another terminal to see transitions)\n\n");

        // Use powermetrics to monitor
        printf("Launching powermetrics...\n\n");
        execlp("powermetrics", "powermetrics",
               "--samplers", "gpu_power", "-i", "200", NULL);
    }
    else if (strcmp(argv[1], "--unlock") == 0) {
        printf("Attempting to remove P-state lock...\n");
        // Try setting cap to max (P15) or removing the cap
        kern_return_t kr = try_set_property(svc, "PerformanceStateCap", 15);
        printf("PerformanceStateCap=15: %s (0x%x)\n",
               kr == KERN_SUCCESS ? "OK" : "failed", kr);
    }
    else {
        int target = atoi(argv[1]);
        if (target < 0 || target > 15) {
            fprintf(stderr, "P-state must be 0-15\n");
            return 1;
        }

        printf("Target: %s\n\n", PSTATE_NAMES[target]);

        // Try all approaches
        printf("=== Approach 1: IORegistryEntrySetCFProperties ===\n");
        scan_properties(svc, target);

        printf("\n=== Approach 2: IOPMAssertionDeclareUserActivity ===\n");
        printf("(Prevents idle but cannot target a specific P-state)\n");

        printf("\n=== Approach 3: Thermal pressure hint ===\n");
        // On macOS, setting a thermal pressure hint can cap the max P-state
        // by making the system think it's thermally constrained
        printf("Checking if thermal pressure controls exist...\n");

        io_iterator_t iter;
        kern_return_t kr = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("ApplePMPThermal"),
            &iter);
        if (kr == KERN_SUCCESS) {
            io_service_t thermal = IOIteratorNext(iter);
            if (thermal) {
                printf("Found ApplePMPThermal\n");
                // Try setting a thermal throttle hint
                kr = try_set_property(thermal, "DesiredMaxTemp", 60);
                printf("  DesiredMaxTemp=60: %s (0x%x)\n",
                       kr == KERN_SUCCESS ? "OK" : "failed", kr);
                IOObjectRelease(thermal);
            }
            IOObjectRelease(iter);
        }

        printf("\n=== Summary ===\n");
        printf("Direct P-state locking on Apple Silicon requires one of:\n");
        printf("  1. SIP disabled + MMIO register writes (Asahi Linux approach)\n");
        printf("  2. A kext/dext that intercepts AGX DVFS calls\n");
        printf("  3. Workload-based frequency pinning (saturate GPU to lock P15,\n");
        printf("     or thermal throttle to cap below P15)\n");
        printf("\nFor benchmarking, the practical approach is:\n");
        printf("  - Lock to P15: run a background Metal compute (1024 threads, 256 iters)\n");
        printf("  - Lock below P15: use 'sudo powermetrics' to verify the duty-cycle\n");
        printf("    approach from gpu_dvfs_bench_v2 holds the desired P-state\n");
    }

    IOObjectRelease(svc);
    return 0;
}
