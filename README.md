# Apple Silicon GPU DVFS Control

Reverse-engineered GPU frequency/voltage scaling on Apple Silicon. Extracts the full DVFS P-state table from the device tree and controls GPU frequency via the CLPC (Closed Loop Performance Controller).

Tested on M4 (Mac16,10, macOS 15.5). Works on any Apple Silicon Mac.

## Quick start

```bash
# Build
xcrun clang -framework IOKit -framework Foundation -framework Metal -O2 \
  -o gpu_freq_ctl gpu_freq_ctl.m

# Show DVFS table (no sudo)
./gpu_freq_ctl table

# Show current GPU state + speed
sudo ./gpu_freq_ctl status

# Throttle GPU (cap package power to 2W)
sudo ./gpu_freq_ctl cap 2

# Restore full speed
sudo ./gpu_freq_ctl uncap

# Sweep all power levels, measure GFLOPS at each
sudo ./gpu_freq_ctl sweep
```

## What this does

The tool writes to `AppleCLPC` (Apple's Closed Loop Performance Controller) via IOKit. The CLPC owns all DVFS decisions — it tracks power consumption via a PID controller and adjusts voltage/frequency states to stay within the configured power budget.

The key property is `` `pkg-low-power-target ``: setting it to a watt value (× 1048576) forces the CLPC to converge on that power level, which selects the appropriate P-state. Setting it to -16777216 (the default) disables the target and lets the GPU run at full speed.

### Verified effect (M4, 10-core GPU)

| Command | GFLOPS (2048² matmul) | GPU Frequency | 
|---------|----------------------|---------------|
| `uncap` (default) | 560 | 1578 MHz (P15) |
| `cap 2` | 41 | 338 MHz (P1) |

Cap → uncap cycle is fully reproducible. The `uncap` command saves and restores the complete CLPC state, including the PID controller gains.

## DVFS P-state table

Extracted from the device tree `perf-states` blob (8 bytes per entry: `[freq_Hz, voltage_mV]`):

```
P-state   Freq MHz   GPU mV   SRAM mV   Corner
-------   --------   ------   -------   ------
P0  (idle)    0        125      780     
P1          338        615      780     
P2          618        645      780     
P3  (base)  796        680      780     ← gpu-perf-base-pstate
P4          928        725      780     
P5          952        780      780     A·lo
P6         1056        780      780     A·hi (+104 MHz, same voltage)
P7         1053        835      835     B·lo
P8         1170        835      835     B·hi (+117 MHz)
P9         1152        875      875     C·lo
P10        1278        875      875     C·hi (+126 MHz)
P11        1204        905      905     D·lo
P12        1338        905      905     D·hi (+134 MHz)
P13        1326        980      980     E·lo
P14        1470        980      980     E·hi (+144 MHz)
P15 (peak) 1578       1055     1055     
```

### Voltage corners

Five voltage levels (780–980 mV) each have two frequencies — a "lo" (energy-efficient) and "hi" (max clock at that voltage). The frequency delta increases with voltage (104 → 144 MHz), reflecting wider timing margin at higher voltages.

### SRAM retention floor

SRAM voltage holds at 780 mV for P0–P6 while GPU logic runs lower. From P7 onward they match. The GPU register file cannot operate below 780 mV.

### DVFS behavior

The CLPC is binary in practice: light loads stay at P3 (796 MHz), any substantial compute jumps to P15 (1578 MHz). Power within P15 scales via clock/power gating (2.5–16W), not P-state stepping. The intermediate states are transient during ramp-up/down.

## How frequency control works

### Architecture

```
 gpu_freq_ctl ──► AppleCLPC (IOKit) ──► PMGR firmware ──► voltage/freq regs
                  (PID controller)      (per-domain)
```

### Writable CLPC properties

| Property | Default (M4) | Effect |
|----------|-------------|--------|
| `` `pkg-low-power-target `` | -16777216 (disabled) | **Primary control**: target power level |
| `~pkg-avg-max-power` | 4915200 (4.69W) | Package average power cap |
| `~pkg-lowpeak-max-power` | 4915200 (4.69W) | Low-peak power cap |
| `~pkg-power-zone-target-0` | 7536640 (7.19W) | Power zone target |
| `~pkg-power-split-gpu-fraction` | 32768 (50%) | GPU share of power budget |

Values are scaled: power values × 1048576 = watts, fraction values × 65536 = ratio.

### Important: recovery

After capping, the CLPC's PID integrator holds state. Simply writing back the original `~pkg-avg-max-power` is **not enough** — you must also restore `` `pkg-low-power-target `` to -16777216 (disabled). The `uncap` command handles this automatically.

If the GPU stays throttled after `uncap`, sleep/wake resets the CLPC firmware state:
```bash
sudo pmset sleepnow
```

## Extraction method

The DVFS table requires no special access — it's in the IORegistry:

```bash
# Dump the GPU device tree node
ioreg -l -w 0 -r -c AppleARMIODevice | grep -A200 '"compatible" = <"gpu,t8132">'
```

Key properties:
- `perf-states` — 16 × 8 bytes: `[freq_Hz(u32), voltage_mV(u32)]`
- `perf-states-sram` — same format, SRAM retention voltages
- `gpu-perf-base-pstate` — base P-state index (3 on M4)
- `perf-state-count` — total P-states including idle (16 on M4)

Decode:
```python
import struct
blob = bytes.fromhex('<hex from ioreg>')
for i in range(16):
    freq, mv = struct.unpack_from('<II', blob, i * 8)
    print(f'P{i}: {freq / 1e6:.0f} MHz  {mv} mV')
```

## Files

| File | Description |
|------|-------------|
| `gpu_freq_ctl.m` | **Main tool** — DVFS table extraction, CLPC control, GPU benchmarking |
| `matmul_dvfs_bench.m` | Tiled FP32 matmul across matrix sizes showing DVFS scaling on GFLOPS |
| `gpu_dvfs_bench.m` | ALU stress sweep with powermetrics |
| `gpu_dvfs_bench_v2.m` | Advanced duty-cycling sweep to characterize lower P-states |
| `parse_dvfs_results.py` | Parser for powermetrics logs |
| `docs/index.html` | Interactive report with charts |
| `experiments/` | RE probes that led to the CLPC discovery |

## Building everything

```bash
# Main tool
xcrun clang -framework IOKit -framework Foundation -framework Metal -O2 \
  -o gpu_freq_ctl gpu_freq_ctl.m

# Matmul benchmark
xcrun clang -framework Metal -framework Foundation -O2 \
  -o matmul_dvfs_bench matmul_dvfs_bench.m

# Stress benchmarks
xcrun clang -framework Metal -framework Foundation -O2 \
  -o gpu_dvfs_bench gpu_dvfs_bench.m
xcrun clang -framework Metal -framework Foundation -O2 \
  -o gpu_dvfs_bench_v2 gpu_dvfs_bench_v2.m
```

## Other Apple Silicon

The device tree format and CLPC interface are consistent across generations:

| SoC | DT compatible | CLPC driver |
|-----|--------------|-------------|
| M1 | `gpu,t8103` | AppleT8103CLPC |
| M2 | `gpu,t8112` | AppleT8112CLPC |
| M3 | `gpu,t8122` | AppleT8122CLPC |
| M4 | `gpu,t8132` | AppleT8132CLPC |

Default CLPC values differ per SoC. The `uncap` command saves state before modification and restores it exactly, so it's safe on any model.

## License

MIT
