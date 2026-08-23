#!/usr/bin/env python3
"""Restore all CLPC properties to original values."""
import ctypes

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
    print("No AppleCLPC"); exit(1)

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
    kr = iokit.IORegistryEntrySetCFProperties(svc, d)
    print(f"  {key_bytes.decode()} = {val}: {'OK' if kr==0 else hex(kr)}")

print("Restoring original CLPC values:")
set_prop(b"~pkg-avg-max-power", 4915200)
set_prop(b"~pkg-lowpeak-max-power", 4915200)
set_prop(b"~pkg-power-zone-target-0", 7536640)
set_prop(b"~pkg-power-zone-target-offset-0", 0)
set_prop(b"~pkg-power-split-gpu-fraction", 32768)
set_prop(b"~pkg-power-split-cpu-fraction", 32768)
set_prop(b"~pkg-power-split-ane-fraction", 0)
set_prop(b"~carplay-power-limit", 16711680)
set_prop(b"~cpu-rot-pwr-engage-thresh", 229376)
set_prop(b"~cpu-rot-pwr-disengage-thresh", 163840)
print("Done. GPU should recover within ~10s.")
