#!/usr/bin/env python3
"""Parse powermetrics GPU log and correlate with M4 DVFS table."""
import sys, re
from collections import defaultdict

# M4 DVFS table from device tree
PERF_STATES = [
    (0,    125, "P0-idle"),
    (338,  615, "P1"),
    (618,  645, "P2"),
    (796,  680, "P3"),
    (928,  725, "P4"),
    (952,  780, "P5-A.lo"),
    (1056, 780, "P6-A.hi"),
    (1053, 835, "P7-B.lo"),
    (1170, 835, "P8-B.hi"),
    (1152, 875, "P9-C.lo"),
    (1278, 875, "P10-C.hi"),
    (1204, 905, "P11-D.lo"),
    (1338, 905, "P12-D.hi"),
    (1326, 980, "P13-E.lo"),
    (1470, 980, "P14-E.hi"),
    (1578,1055, "P15-peak"),
]

FREQ_TO_PS = {}
for freq, mv, name in PERF_STATES:
    FREQ_TO_PS[freq] = (mv, name)

def parse_powermetrics(path):
    """Extract (timestamp_idx, freq_mhz, power_mw, residency_dict) per sample."""
    samples = []
    cur_freq = None
    cur_residency = {}

    with open(path) as f:
        for line in f:
            m = re.match(r'\s*GPU HW active frequency:\s+([\d.]+)\s*MHz', line)
            if m:
                cur_freq = float(m.group(1))

            m = re.match(r'\s*GPU HW active residency:\s+([\d.]+)%\s*\((.+)\)', line)
            if m:
                detail = m.group(2)
                cur_residency = {}
                for fm in re.finditer(r'(\d+)\s*MHz:\s*([\d.]+)%', detail):
                    freq = int(fm.group(1))
                    pct = float(fm.group(2))
                    if pct > 0:
                        cur_residency[freq] = pct

            m = re.match(r'\s*GPU Power:\s+([\d.]+)\s*(mW|W)', line)
            if m:
                power = float(m.group(1))
                if m.group(2) == 'W':
                    power *= 1000
                samples.append({
                    'freq': cur_freq or 0,
                    'power': power,
                    'residency': dict(cur_residency),
                })
    return samples

def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <powermetrics_log>")
        sys.exit(1)

    samples = parse_powermetrics(sys.argv[1])
    if not samples:
        print("No samples found"); sys.exit(1)

    print(f"Parsed {len(samples)} samples\n")

    # Print full DVFS table with voltage corners
    print("=" * 72)
    print("M4 GPU DVFS Table (device tree: perf-states)")
    print("=" * 72)
    print(f"{'P-state':<12} {'Freq MHz':>9} {'Voltage mV':>11} {'Corner':>8} {'Notes'}")
    print("-" * 72)

    prev_v = 0
    for freq, mv, name in PERF_STATES:
        corner = ""
        notes = ""
        if mv == prev_v and mv > 0:
            corner = "  ^same"
            notes = f"(+{freq - PERF_STATES[PERF_STATES.index((freq,mv,name))-1][0]} MHz at same voltage)"
        prev_v = mv
        print(f"  {name:<10} {freq:>9} {mv:>11} {corner:>8} {notes}")
    print()

    # Voltage corner summary
    corners = defaultdict(list)
    for freq, mv, name in PERF_STATES:
        if freq > 0:
            corners[mv].append((freq, name))

    print("=" * 60)
    print("Voltage Corners (same voltage, different frequencies)")
    print("=" * 60)
    for mv in sorted(corners.keys()):
        entries = corners[mv]
        if len(entries) == 1:
            f, n = entries[0]
            print(f"  {mv:4d} mV: {f:5d} MHz ({n})")
        else:
            lo = min(entries, key=lambda x: x[0])
            hi = max(entries, key=lambda x: x[0])
            delta = hi[0] - lo[0]
            print(f"  {mv:4d} mV: {lo[0]:5d} MHz ({lo[1]}) ←→ {hi[0]:5d} MHz ({hi[1]})  Δ={delta} MHz")
    print()

    # Power analysis per frequency bucket
    freq_power = defaultdict(list)
    for s in samples:
        for freq, pct in s['residency'].items():
            if pct > 50:  # dominant frequency
                freq_power[freq].append(s['power'])

    if freq_power:
        print("=" * 60)
        print("Measured Power by Dominant Frequency")
        print("=" * 60)
        print(f"{'Freq MHz':>9} {'Samples':>8} {'Avg mW':>8} {'Min mW':>8} {'Max mW':>8} {'Voltage':>8}")
        print("-" * 60)
        for freq in sorted(freq_power.keys()):
            powers = freq_power[freq]
            mv_info = FREQ_TO_PS.get(freq, (0, "?"))
            print(f"  {freq:>7} {len(powers):>8} {sum(powers)/len(powers):>8.1f} "
                  f"{min(powers):>8.1f} {max(powers):>8.1f} {mv_info[0]:>7} mV")
        print()

    # Time series (first 60 samples)
    print("=" * 60)
    print("Time Series (first 60 samples)")
    print("=" * 60)
    print(f"{'#':>4} {'Freq MHz':>9} {'Power mW':>9} {'Dominant P-state'}")
    print("-" * 50)
    for i, s in enumerate(samples[:60]):
        dominant = max(s['residency'].items(), key=lambda x: x[1]) if s['residency'] else (0, 0)
        ps_info = FREQ_TO_PS.get(dominant[0], (0, f"?@{dominant[0]}"))
        print(f"  {i:>3} {s['freq']:>9.0f} {s['power']:>9.0f}   {ps_info[1]} ({dominant[1]:.1f}%)")

if __name__ == '__main__':
    main()
