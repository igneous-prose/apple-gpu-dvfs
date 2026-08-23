#!/usr/bin/env python3
"""Reset CLPC PID integrator by zeroing Ki, then restoring."""
import ctypes, time, sys

iokit = ctypes.CDLL("/System/Library/Frameworks/IOKit.framework/IOKit")
cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")

iokit.IOServiceGetMatchingService.restype = ctypes.c_uint32
iokit.IOServiceGetMatchingService.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
iokit.IOServiceMatching.restype = ctypes.c_void_p
iokit.IOServiceMatching.argtypes = [ctypes.c_char_p]
iokit.IORegistryEntrySetCFProperties.restype = ctypes.c_int
iokit.IORegistryEntrySetCFProperties.argtypes = [ctypes.c_uint32, ctypes.c_void_p]

svc = iokit.IOServiceGetMatchingService(0, iokit.IOServiceMatching(b"AppleCLPC"))
if not svc:
    print("No AppleCLPC"); sys.exit(1)

cf.CFStringCreateWithCString.restype = ctypes.c_void_p
cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
cf.CFNumberCreate.restype = ctypes.c_void_p
cf.CFNumberCreate.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
cf.CFDictionaryCreateMutable.restype = ctypes.c_void_p
cf.CFDictionaryCreateMutable.argtypes = [ctypes.c_void_p, ctypes.c_long, ctypes.c_void_p, ctypes.c_void_p]
cf.CFDictionarySetValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]

def set_prop(key_bytes, val):
    k = cf.CFStringCreateWithCString(None, key_bytes, 0x08000100)
    v_val = ctypes.c_int64(val)
    v = cf.CFNumberCreate(None, 4, ctypes.byref(v_val))
    d = cf.CFDictionaryCreateMutable(None, 1, None, None)
    cf.CFDictionarySetValue(d, k, v)
    return iokit.IORegistryEntrySetCFProperties(svc, d)

# Step 1: Zero all Ki gains (clear PID integrator)
print("Step 1: Zeroing PID integrator gains...")
ki_props = [
    (b"`pkg-avg-limiter-ki", 2466),
    (b"`pkg-lowpeak-limiter-ki", 29025),
    (b"`cpu-avg-limiter-ki", 20132),
    (b"`cpu-lowpeak-limiter-ki", 134217),
]
for key, _ in ki_props:
    kr = set_prop(key, 0)
    print(f"  {key.decode()} = 0: {'OK' if kr==0 else hex(kr)}")

# Step 2: Set power cap high to allow ramp
print("\nStep 2: Set high power cap...")
set_prop(b"~pkg-avg-max-power", 20971520)  # 20W
set_prop(b"~pkg-lowpeak-max-power", 20971520)

print("Waiting 3s for CLPC to ramp...")
time.sleep(3)

# Step 3: Restore original Ki gains
print("\nStep 3: Restoring PID gains...")
for key, orig in ki_props:
    kr = set_prop(key, orig)
    print(f"  {key.decode()} = {orig}: {'OK' if kr==0 else hex(kr)}")

# Step 4: Restore original power caps
print("\nStep 4: Restoring power caps...")
set_prop(b"~pkg-avg-max-power", 4915200)
set_prop(b"~pkg-lowpeak-max-power", 4915200)
set_prop(b"~pkg-power-zone-target-0", 7536640)

print("\nDone. GPU should ramp within seconds.")
