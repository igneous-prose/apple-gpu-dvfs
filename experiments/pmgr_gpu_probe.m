// pmgr_gpu_probe — read GPU PMGR power state registers via IOKit MMIO
// Reads the PMGR PS (power state) register for the GPU clock domain
// to observe the actual hardware P-state, and attempts to write it.
//
// Build: xcrun clang -framework IOKit -framework Foundation -O2 -o pmgr_gpu_probe pmgr_gpu_probe.m
// Run:   sudo ./pmgr_gpu_probe

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// From device tree analysis:
// GPU clock-ids = 0x17d (381)
// PMGR PS registers: each domain gets 8 bytes
// The PMGR base varies by SoC; we read it from IODeviceMemory

static int try_map_pmgr(void) {
    io_iterator_t iter;
    kern_return_t kr;

    // Find the pmgr device
    kr = IOServiceGetMatchingServices(kIOMainPortDefault,
        IOServiceNameMatching("pmgr"), &iter);
    if (kr != KERN_SUCCESS) {
        printf("pmgr not found: 0x%x\n", kr);
        return -1;
    }

    io_service_t svc = IOIteratorNext(iter);
    IOObjectRelease(iter);
    if (!svc) {
        printf("No pmgr service\n");
        return -1;
    }

    printf("Found pmgr service\n");

    // Try to open a connection for MMIO access
    io_connect_t conn;
    kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    printf("IOServiceOpen(pmgr, type=0): 0x%x (%s)\n", kr,
           kr == KERN_SUCCESS ? "OK" :
           kr == 0xe00002c9 ? "not permitted (SIP)" :
           kr == 0xe00002cd ? "exclusive access" : "failed");

    if (kr == KERN_SUCCESS) {
        // Try to map the PS register region
        mach_vm_address_t addr = 0;
        mach_vm_size_t size = 0;
        kr = IOConnectMapMemory64(conn, 0, mach_task_self(),
            &addr, &size, kIOMapAnywhere);
        printf("IOConnectMapMemory64: 0x%x (addr=0x%llx, size=0x%llx)\n",
               kr, addr, size);

        if (kr == KERN_SUCCESS) {
            printf("Mapped PMGR at 0x%llx, size 0x%llx\n", addr, size);

            // Read GPU PS register
            uint32_t gpu_domain = 0x17d;
            uint32_t ps_offset = gpu_domain * 8;
            if (ps_offset + 8 <= size) {
                volatile uint32_t *ps_reg = (volatile uint32_t *)(addr + ps_offset);
                uint32_t val = *ps_reg;
                printf("\nGPU PS register (domain 0x%x, offset 0x%x):\n", gpu_domain, ps_offset);
                printf("  Raw: 0x%08x\n", val);
                printf("  Bits [3:0]   device_state = %u\n", val & 0xf);
                printf("  Bits [7:4]   target_pstate = %u\n", (val >> 4) & 0xf);
                printf("  Bits [11:8]  actual_pstate = %u\n", (val >> 8) & 0xf);
            } else {
                printf("PS offset 0x%x exceeds mapped size 0x%llx\n", ps_offset, size);
            }
        }
        IOServiceClose(conn);
    }

    // Alternative: try AGX accelerator MMIO
    printf("\n--- Trying AGX MMIO ---\n");
    kr = IOServiceGetMatchingServices(kIOMainPortDefault,
        IOServiceMatching("AGXAcceleratorG16G"), &iter);
    if (kr == KERN_SUCCESS) {
        io_service_t agx = IOIteratorNext(iter);
        IOObjectRelease(iter);
        if (agx) {
            // Try each user client type 0-10
            for (uint32_t type = 0; type <= 5; type++) {
                io_connect_t agx_conn;
                kr = IOServiceOpen(agx, mach_task_self(), type, &agx_conn);
                if (kr == KERN_SUCCESS) {
                    printf("IOServiceOpen(AGX, type=%u): OK\n", type);

                    // Try to map each memory index
                    for (uint32_t idx = 0; idx < 5; idx++) {
                        mach_vm_address_t addr = 0;
                        mach_vm_size_t size = 0;
                        kr = IOConnectMapMemory64(agx_conn, idx, mach_task_self(),
                            &addr, &size, kIOMapAnywhere | kIOMapReadOnly);
                        if (kr == KERN_SUCCESS) {
                            printf("  MapMemory(idx=%u): addr=0x%llx size=0x%llx\n",
                                   idx, addr, size);
                        }
                    }

                    // Try external methods that might read perf state
                    // AGX external method selectors are typically 0-200+
                    // Try to find one that returns perf state info
                    for (uint32_t sel = 0; sel <= 20; sel++) {
                        uint64_t output[8] = {0};
                        uint32_t outputCnt = 8;
                        kr = IOConnectCallScalarMethod(agx_conn, sel,
                            NULL, 0, output, &outputCnt);
                        if (kr == KERN_SUCCESS) {
                            printf("  ExtMethod(%u): output[0]=0x%llx cnt=%u\n",
                                   sel, output[0], outputCnt);
                        } else if (kr != 0xe00002c2 && kr != 0xe00002bc) {
                            // Not unsupported or not permitted — interesting
                            printf("  ExtMethod(%u): 0x%x\n", sel, kr);
                        }
                    }

                    IOServiceClose(agx_conn);
                } else if (kr != 0xe00002c9 && kr != 0xe00002cd) {
                    printf("IOServiceOpen(AGX, type=%u): 0x%x\n", type, kr);
                }
            }
            IOObjectRelease(agx);
        }
    }

    IOObjectRelease(svc);
    return 0;
}

int main(int argc, char **argv) {
    if (geteuid() != 0) {
        fprintf(stderr, "Need root (sudo)\n");
        return 1;
    }

    printf("=== M4 GPU PMGR Probe ===\n\n");
    printf("GPU clock domain: 0x17d (381)\n");
    printf("GPU clock-gates: 0x13d, 0x13c\n");
    printf("GPU power-gates: 0x13d, 0x13c\n\n");

    try_map_pmgr();

    // Also try IOPerfControl — the kernel's performance controller interface
    printf("\n--- IOPerfControl ---\n");
    io_iterator_t iter;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault,
        IOServiceMatching("IOPerfControl"), &iter);
    if (kr == KERN_SUCCESS) {
        io_service_t svc;
        while ((svc = IOIteratorNext(iter))) {
            io_name_t name;
            IORegistryEntryGetName(svc, name);
            printf("Found: %s\n", name);

            io_connect_t conn;
            kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
            printf("  Open: 0x%x\n", kr);
            if (kr == KERN_SUCCESS) IOServiceClose(conn);

            IOObjectRelease(svc);
        }
        IOObjectRelease(iter);
    } else {
        printf("IOPerfControl not found\n");
    }

    return 0;
}
