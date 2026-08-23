# Apple M4 GPU DVFS Reverse Engineering

Reverse-engineered DVFS (Dynamic Voltage and Frequency Scaling) voltage corners from the Apple M4 GPU, with reproducible Metal compute benchmarks and **CLPC-based GPU frequency control**.

## Findings

The M4 GPU (`AGXAcceleratorG16G`, device tree `gpu,t8132`, 10 cores) has **16 P-states** across **11 voltage levels** with **5 paired voltage corners**.

| P-state | Freq (MHz) | GPU Voltage (mV) | SRAM Voltage (mV) | Corner |
|---------|-----------|-------------------|---------------------|--------|
| P0      | 0 (idle)  | 125               | 780                 | idle   |
| P1      | 338       | 615               | 780                 |        |
| P2      | 618       | 645               | 780                 |        |
| **P3**  | **796**   | **680**           | **780**             | **base** |
| P4      | 928       | 725               | 780                 |        |
| P5      | 952       | 780               | 780                 | A·lo   |
| P6      | 1056      | 780               | 780                 | A·hi (+104 MHz) |
| P7      | 1053      | 835               | 835                 | B·lo   |
| P8      | 1170      | 835               | 835                 | B·hi (+117 MHz) |
| P9      | 1152      | 875               | 875                 | C·lo   |
| P10     | 1278      | 875               | 875                 | C·hi (+126 MHz) |
| P11     | 1204      | 905               | 905                 | D·lo   |
| P12     | 1338      | 905               | 905                 | D·hi (+134 MHz) |
| P13     | 1326      | 980               | 980                 | E·lo   |
| P14     | 1470      | 980               | 980                 | E·hi (+144 MHz) |
| **P15** | **1578**  | **1055**          | **1055**            | **peak** |

### Key observations

- **Binary DVFS behavior**: The CLPC controller is aggressive — light loads stay at P3 (796 MHz), any substantial compute jumps directly to P15 (1578 MHz). Intermediate P-states are transient.
- **Voltage corners**: At each voltage level from 780 mV upward, two frequencies are available. The delta increases with voltage (104 → 144 MHz), reflecting wider timing margin.
- **SRAM retention floor**: SRAM voltage holds at 780 mV for P0–P6 while GPU logic runs lower. From P7 onward they match.
- **Power range**: 0 mW (idle) to ~16 W (peak stress at P15). Power within P15 scales via clock/power gating, not P-state stepping.
- **Matmul scaling**: GFLOPS climbs from 1.8 (16×16, DVFS at P3) to 554 (2048×2048, DVFS locked at P15) — a 300× range.

## GPU frequency control via CLPC

**The main finding**: GPU frequency can be controlled via the `AppleCLPC` (Closed Loop Performance Controller) IOKit service. The CLPC exposes writable power budget properties that directly control DVFS behavior.

### What works

The `AppleCLPC` service accepts property writes (via `IORegistryEntrySetCFProperties`) for power budget parameters. Setting a low package power cap forces the CLPC to throttle the GPU to lower P-states:

```bash
# Build the CLPC control tool
xcrun clang -framework IOKit -framework Foundation -O2 \
  -o clpc_gpu_control clpc_gpu_control.m

# Dump all CLPC properties (shows current power budgets)
sudo ./clpc_gpu_control --dump

# Cap package power to 2W → GPU throttles to P1 (338 MHz)
sudo ./clpc_gpu_control --cap 2

# Set GPU power fraction to 25% of package budget
sudo ./clpc_gpu_control --split 25
```

### Writable CLPC properties

| Property | Default | Unit | Effect |
|----------|---------|------|--------|
| `~pkg-avg-max-power` | 4915200 | mW×1048576 (4.69W) | Package average power cap |
| `~pkg-lowpeak-max-power` | 4915200 | (4.69W) | Low-peak power cap |
| `~pkg-power-zone-target-0` | 7536640 | (7.19W) | Power zone target |
| `~pkg-power-split-gpu-fraction` | 32768 | ×65536 (50%) | GPU share of power budget |
| `~pkg-power-split-cpu-fraction` | 32768 | (50%) | CPU share of power budget |
| `~carplay-power-limit` | 16711680 | (15.94W) | CarPlay mode power limit |

PID controller gains (`` ` `` prefix) are also writable:

| Property | Default | Purpose |
|----------|---------|---------|
| `` `pkg-avg-limiter-kp`` | 72645 | Proportional gain |
| `` `pkg-avg-limiter-ki`` | 2466 | Integral gain |
| `` `pkg-lowpeak-limiter-kp`` | 261725 | Low-peak proportional |
| `` `pkg-lowpeak-limiter-ki`` | 29025 | Low-peak integral |

### Verified effect

Setting `~pkg-avg-max-power` to 2W (2097152 raw) causes:
- GPU frequency drops from **1578 MHz → 338 MHz** (P15 → P1)
- Matmul GFLOPS drops from **554 → 41** (13.5× reduction)
- `powermetrics` confirms GPU locked at 338 MHz with ~500 mW power

### Caution: slow recovery

The CLPC has long PID time constants (`#pkg-avg-limiter-input-tc = 900`, likely seconds). After aggressive throttling, the GPU takes **minutes** to recover even after restoring original values. Sleep/wake (`sudo pmset sleepnow`) resets the CLPC state immediately.

```bash
# Restore original values after testing
sudo python3 restore_clpc.py

# If GPU stays throttled, force CLPC reset via sleep/wake
sudo pmset sleepnow
```

### What doesn't work

- **Direct P-state selection**: No IOKit property directly sets a specific P-state (P0-P15). Control is indirect via power budget caps.
- **AGX property writes**: All writes to `AGXAcceleratorG16G` return `kIOReturnUnsupported` (0xe00002c7).
- **PMGR MMIO access**: PMGR registers are SIP-protected; `IOServiceOpen` on the PMGR device fails.
- **sysctl**: No GPU frequency/DVFS sysctls exist.

### Architecture

```
User space                    Kernel                      Hardware
                                                          
clpc_gpu_control.m ───────► AppleCLPC ──────────────► PMGR firmware
  (IORegistryEntry             (PID controller,           (voltage/freq
   SetCFProperties)             power budget               registers,
                                tracking)                  per-domain)
                                    │
                                    ▼
                              AGXAcceleratorG16G
                                (GPU driver,
                                 firmware mailbox
                                 via gfx-asc RTKit)
```

The CLPC is a separate kernel driver (`com.apple.driver.AppleT8132CLPC`) that sits between the PMGR and all workload drivers. It implements a closed-loop PID controller that tracks power consumption and adjusts DVFS states to stay within the configured budget.

## DVFS table extraction

The DVFS table is stored in the macOS device tree under the GPU node. No kernel extensions or jailbreak required.

```bash
# Dump GPU device tree properties
ioreg -l -w 0 -r -c AppleARMIODevice | grep -A200 '"compatible" = <"gpu,t8132">'

# Key properties:
#   "perf-states"          — 16 × 8-byte entries: [freq_Hz(u32), voltage_mV(u32)]
#   "perf-states-sram"     — same format, SRAM retention voltages
#   "gpu-num-perf-states"  — 15 (little-endian u32)
#   "perf-state-count"     — 16 (including idle)
#   "gpu-perf-base-pstate" — 3 (P3 = 796 MHz)
```

Decode the binary blob:

```python
import struct
blob = bytes.fromhex('000000007d000000807825146702000080eed524850200...')
for i in range(16):
    freq, mv = struct.unpack_from('<II', blob, i * 8)
    print(f'P{i}: {freq / 1e6:.0f} MHz  {mv} mV')
```

## Repository contents

| File | Description |
|------|-------------|
| **CLPC control** | |
| `clpc_gpu_control.m` | Read/write AppleCLPC power budget properties to control GPU DVFS |
| `restore_clpc.py` | Restore all CLPC properties to factory defaults |
| `clpc_reset.py` | Reset CLPC PID integrator (zero Ki gains, raise cap, restore) |
| **DVFS probes** | |
| `gpu_pstate_lock.m` | Probe AGX IOKit interface for direct P-state control (negative result) |
| `pmgr_gpu_probe.m` | Probe PMGR MMIO and AGX user client for register access |
| **Benchmarks** | |
| `gpu_dvfs_bench.m` | Basic DVFS stress sweep — variable ALU intensity with powermetrics |
| `gpu_dvfs_bench_v2.m` | Advanced sweep with duty-cycling + threadgroup control |
| `matmul_dvfs_bench.m` | Tiled FP32 matmul across matrix sizes showing DVFS scaling on GFLOPS |
| **Analysis** | |
| `parse_dvfs_results.py` | Parser for powermetrics logs — per-P-state power/frequency analysis |
| `docs/index.html` | Interactive report with charts (freq-voltage, power sweep, matmul scaling) |

## Build and run

Requires macOS with Apple Silicon (tested on M4, Mac16,10, macOS 15.5 / 25D125).

### CLPC GPU frequency control

```bash
# Build
xcrun clang -framework IOKit -framework Foundation -O2 \
  -o clpc_gpu_control clpc_gpu_control.m

# Dump current CLPC state
sudo ./clpc_gpu_control --dump

# Cap GPU power (forces lower P-state)
sudo ./clpc_gpu_control --cap 2      # 2W cap → P1 (338 MHz)
sudo ./clpc_gpu_control --cap 4.69   # restore default

# Restore everything after testing
sudo python3 restore_clpc.py
```

### DVFS stress benchmark

```bash
xcrun clang -framework Metal -framework Foundation -O2 \
  -o gpu_dvfs_bench gpu_dvfs_bench.m

./gpu_dvfs_bench --no-power        # without powermetrics
sudo ./gpu_dvfs_bench              # with power measurement
```

### Matmul DVFS scaling

```bash
xcrun clang -framework Metal -framework Foundation -O2 \
  -o matmul_dvfs_bench matmul_dvfs_bench.m

./matmul_dvfs_bench                # human-readable
./matmul_dvfs_bench --csv          # CSV for analysis
```

### Live frequency monitoring

```bash
sudo powermetrics --samplers gpu_power -i 100
```

## Adapting to other Apple Silicon

The extraction and CLPC control methods work on any Apple Silicon Mac. Change the `compatible` string for the device tree query:

| SoC | Device tree | GPU class | CLPC driver |
|-----|------------|-----------|-------------|
| M1  | `gpu,t8103` | AGXAcceleratorG13G | AppleT8103CLPC |
| M2  | `gpu,t8112` | ? | AppleT8112CLPC |
| M3  | `gpu,t8122` | ? | AppleT8122CLPC |
| M4  | `gpu,t8132` | AGXAcceleratorG16G | AppleT8132CLPC |

The `perf-states` blob format (8 bytes per entry: `[freq_Hz, voltage_mV]`) and CLPC property interface (`~pkg-*`, `` `pkg-*``) are consistent across generations. Default values will differ per SoC.

## License

MIT
