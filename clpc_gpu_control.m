// clpc_gpu_control — probe and control GPU P-state via AppleCLPC
// The CLPC (Closed Loop Performance Controller) owns DVFS decisions.
// It exposes writable properties prefixed with ~ and ` for power targets.
//
// Build: xcrun clang -framework IOKit -framework Foundation -O2 -o clpc_gpu_control clpc_gpu_control.m
// Run:   sudo ./clpc_gpu_control --dump          (dump all CLPC properties)
//        sudo ./clpc_gpu_control --cap <watts>    (try to cap GPU power)
//        sudo ./clpc_gpu_control --split <pct>    (try GPU power split %)
//        sudo ./clpc_gpu_control --client         (probe user client methods)

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static io_service_t find_clpc(void) {
    io_iterator_t iter;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault,
        IOServiceMatching("AppleCLPC"), &iter);
    if (kr != KERN_SUCCESS) return 0;
    io_service_t svc = IOIteratorNext(iter);
    IOObjectRelease(iter);
    return svc;
}

static kern_return_t try_set_int(io_service_t svc, const char *key, int64_t value) {
    CFStringRef cfKey = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFNumberRef cfVal = CFNumberCreate(NULL, kCFNumberSInt64Type, &value);
    CFMutableDictionaryRef dict = CFDictionaryCreateMutable(
        NULL, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(dict, cfKey, cfVal);
    kern_return_t kr = IORegistryEntrySetCFProperties(svc, dict);
    CFRelease(dict);
    CFRelease(cfVal);
    CFRelease(cfKey);
    return kr;
}

static void dump_clpc(io_service_t svc) {
    CFMutableDictionaryRef props = NULL;
    kern_return_t kr = IORegistryEntryCreateCFProperties(svc, &props, NULL, 0);
    if (kr != KERN_SUCCESS || !props) {
        printf("Cannot read properties: 0x%x\n", kr);
        return;
    }

    printf("=== AppleCLPC Properties ===\n\n");

    // Categorize by prefix
    const char *categories[] = {"Power targets (~pkg-)", "GPU-related", "Limiters", "Other"};

    CFIndex count = CFDictionaryGetCount(props);
    CFStringRef *keys = malloc(sizeof(CFStringRef) * count);
    CFTypeRef *values = malloc(sizeof(CFTypeRef) * count);
    CFDictionaryGetKeysAndValues(props, (const void **)keys, (const void **)values);

    // First pass: GPU and power related
    printf("--- GPU & Power Properties ---\n");
    for (CFIndex i = 0; i < count; i++) {
        char key[256];
        CFStringGetCString(keys[i], key, sizeof(key), kCFStringEncodingUTF8);

        if (!strstr(key, "gpu") && !strstr(key, "GPU") &&
            !strstr(key, "pkg-power") && !strstr(key, "power-zone") &&
            !strstr(key, "power-split") && !strstr(key, "max-power") &&
            !strstr(key, "avg-max") && !strstr(key, "lowpeak")) continue;

        if (CFGetTypeID(values[i]) == CFNumberGetTypeID()) {
            int64_t val;
            CFNumberGetValue((CFNumberRef)values[i], kCFNumberSInt64Type, &val);

            // Decode known scaled values
            double decoded = 0;
            int is_power = (strstr(key, "power") != NULL);
            if (is_power && val > 0 && val < 0x7FFFFFFF) {
                decoded = (double)val / 1048576.0;
                printf("  %-45s = %lld (%.2f W)\n", key, val, decoded);
            } else if (strstr(key, "fraction")) {
                decoded = (double)val / 65536.0 * 100.0;
                printf("  %-45s = %lld (%.1f%%)\n", key, val, decoded);
            } else {
                printf("  %-45s = %lld\n", key, val);
            }
        }
    }

    // Second pass: writable properties (~ and ` prefixed)
    printf("\n--- Writable Properties (~ prefix) ---\n");
    for (CFIndex i = 0; i < count; i++) {
        char key[256];
        CFStringGetCString(keys[i], key, sizeof(key), kCFStringEncodingUTF8);
        if (key[0] != '~') continue;

        if (CFGetTypeID(values[i]) == CFNumberGetTypeID()) {
            int64_t val;
            CFNumberGetValue((CFNumberRef)values[i], kCFNumberSInt64Type, &val);
            double watts = (double)val / 1048576.0;
            if (strstr(key, "power") && val > 0 && val < 0x7FFFFFFF)
                printf("  %-45s = %lld (%.2f W)\n", key, val, watts);
            else if (strstr(key, "fraction"))
                printf("  %-45s = %lld (%.1f%%)\n", key, val, (double)val / 65536.0 * 100.0);
            else
                printf("  %-45s = %lld\n", key, val);
        }
    }

    printf("\n--- Writable Properties (` prefix) ---\n");
    for (CFIndex i = 0; i < count; i++) {
        char key[256];
        CFStringGetCString(keys[i], key, sizeof(key), kCFStringEncodingUTF8);
        if (key[0] != '`') continue;

        if (CFGetTypeID(values[i]) == CFNumberGetTypeID()) {
            int64_t val;
            CFNumberGetValue((CFNumberRef)values[i], kCFNumberSInt64Type, &val);
            double watts = (double)val / 1048576.0;
            if (strstr(key, "power") && val > 0 && val < 0x7FFFFFFF)
                printf("  %-45s = %lld (%.2f W)\n", key, val, watts);
            else
                printf("  %-45s = %lld\n", key, val);
        }
    }

    free(keys);
    free(values);
    CFRelease(props);
}

int main(int argc, char **argv) {
    if (geteuid() != 0) {
        fprintf(stderr, "Need root (sudo)\n");
        return 1;
    }

    io_service_t svc = find_clpc();
    if (!svc) {
        fprintf(stderr, "AppleCLPC not found\n");
        return 1;
    }

    if (argc < 2 || strcmp(argv[1], "--dump") == 0) {
        dump_clpc(svc);

        // Also try writing to key CLPC properties
        printf("\n=== Write Attempts ===\n\n");

        // Try setting GPU power fraction (this could cap GPU P-state)
        struct { const char *key; int64_t val; const char *desc; } attempts[] = {
            {"~pkg-power-split-gpu-fraction", 16384, "GPU fraction → 25%"},
            {"~pkg-avg-max-power", 2097152, "Avg max power → 2W"},
            {"~pkg-lowpeak-max-power", 2097152, "Lowpeak max → 2W"},
            {"~pkg-power-zone-target-0", 3145728, "Power zone 0 → 3W"},
            {"~carplay-power-limit", 2097152, "Carplay limit → 2W"},
            {"~cpu-rot-pwr-engage-thresh", 131072, "CPU ROT engage → lower"},
            {"`pkg-avg-limiter-kp", 72645, "Avg limiter Kp (same val)"},
            {"`pkg-low-power-target", 1048576, "Low power target → 1W"},
        };

        for (int i = 0; i < sizeof(attempts)/sizeof(attempts[0]); i++) {
            kern_return_t kr = try_set_int(svc, attempts[i].key, attempts[i].val);
            printf("  %-45s → %s (0x%x)\n", attempts[i].desc,
                   kr == KERN_SUCCESS ? "ACCEPTED" :
                   kr == 0xe00002c7 ? "unsupported" :
                   kr == 0xe00002bc ? "not permitted" : "failed", kr);
        }
    }
    else if (strcmp(argv[1], "--client") == 0) {
        printf("=== Probing AppleCLPCUserClient ===\n\n");

        io_connect_t conn;
        for (uint32_t type = 0; type <= 3; type++) {
            kern_return_t kr = IOServiceOpen(svc, mach_task_self(), type, &conn);
            if (kr == KERN_SUCCESS) {
                printf("Opened type=%u\n", type);

                // Probe scalar methods
                for (uint32_t sel = 0; sel < 30; sel++) {
                    uint64_t output[8] = {0};
                    uint32_t outputCnt = 8;
                    kr = IOConnectCallScalarMethod(conn, sel, NULL, 0, output, &outputCnt);
                    if (kr == KERN_SUCCESS) {
                        printf("  scalar sel=%u: out[%u] =", sel, outputCnt);
                        for (uint32_t j = 0; j < outputCnt; j++)
                            printf(" 0x%llx", output[j]);
                        printf("\n");
                    } else if (kr != 0xe00002c2 && kr != 0xe00002be) {
                        printf("  scalar sel=%u: 0x%x\n", sel, kr);
                    }
                }

                // Probe struct methods
                for (uint32_t sel = 0; sel < 20; sel++) {
                    char outbuf[1024];
                    size_t outsize = sizeof(outbuf);
                    memset(outbuf, 0, sizeof(outbuf));
                    kr = IOConnectCallStructMethod(conn, sel, NULL, 0, outbuf, &outsize);
                    if (kr == KERN_SUCCESS && outsize > 0) {
                        printf("  struct sel=%u: %zu bytes:", sel, outsize);
                        uint32_t *p = (uint32_t *)outbuf;
                        for (size_t j = 0; j < outsize/4 && j < 8; j++)
                            printf(" %08x", p[j]);
                        if (outsize > 32) printf(" ...");
                        printf("\n");
                    }
                }

                // Probe memory maps
                for (uint32_t idx = 0; idx < 8; idx++) {
                    mach_vm_address_t addr = 0;
                    mach_vm_size_t size = 0;
                    kr = IOConnectMapMemory64(conn, idx, mach_task_self(),
                        &addr, &size, kIOMapAnywhere | kIOMapReadOnly);
                    if (kr == KERN_SUCCESS && size > 0) {
                        printf("  memory idx=%u: addr=0x%llx size=0x%llx\n",
                               idx, addr, size);
                        volatile uint32_t *p = (volatile uint32_t *)addr;
                        printf("    first 8 u32s:");
                        for (int j = 0; j < 8 && j*4 < (int)size; j++)
                            printf(" %08x", p[j]);
                        printf("\n");
                    }
                }

                IOServiceClose(conn);
            } else if (kr != 0xe00002c7) {
                printf("Open type=%u: 0x%x\n", type, kr);
            }
        }
    }
    else if (strcmp(argv[1], "--cap") == 0 && argc > 2) {
        double watts = atof(argv[2]);
        int64_t scaled = (int64_t)(watts * 1048576.0);
        printf("Setting package power cap to %.1f W (raw=%lld)\n", watts, scaled);

        kern_return_t kr;
        kr = try_set_int(svc, "~pkg-avg-max-power", scaled);
        printf("  ~pkg-avg-max-power: %s (0x%x)\n",
               kr == KERN_SUCCESS ? "OK" : "failed", kr);
        kr = try_set_int(svc, "~pkg-lowpeak-max-power", scaled);
        printf("  ~pkg-lowpeak-max-power: %s (0x%x)\n",
               kr == KERN_SUCCESS ? "OK" : "failed", kr);
    }
    else if (strcmp(argv[1], "--split") == 0 && argc > 2) {
        double pct = atof(argv[2]);
        int64_t scaled = (int64_t)(pct / 100.0 * 65536.0);
        printf("Setting GPU power fraction to %.0f%% (raw=%lld)\n", pct, scaled);

        kern_return_t kr = try_set_int(svc, "~pkg-power-split-gpu-fraction", scaled);
        printf("  ~pkg-power-split-gpu-fraction: %s (0x%x)\n",
               kr == KERN_SUCCESS ? "OK" : "failed", kr);
    }

    IOObjectRelease(svc);
    return 0;
}
