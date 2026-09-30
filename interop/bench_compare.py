"""Report optimized, matching memory workloads; performance ratios are informational."""
import argparse
from pathlib import Path
import re
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PATTERN = re.compile(r"^\s*(tiled i16|f32|f64|i16|i32)\s+\d+-bit\s+(\d+x\d+).*?(?:write\s+([\d.]+) MB/s\s+)?read\s+([\d.]+) MB/s$", re.MULTILINE)


def run(command):
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, check=True)
    output = result.stdout + result.stderr
    rows = {}
    for dtype, geometry, write, read in PATTERN.findall(output):
        if write:
            rows[(dtype, geometry, "write")] = float(write)
        rows[(dtype, geometry, "read")] = float(read)
    if len(rows) != 9 or "all round-trips verified" not in output:
        raise RuntimeError(f"unexpected benchmark output:\n{output}")
    return rows, output.splitlines()[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs", type=int, default=5)
    args = parser.parse_args()
    if args.runs < 3:
        parser.error("at least three independent runs are required for medians")
    commands = {
        "zigfitsio": ["zig", "build", "bench", "-Doptimize=ReleaseFast"],
        "CFITSIO": [str(ROOT / "interop/build/bench_memory")],
    }
    samples = {name: [] for name in commands}
    for _ in range(args.runs):
        for name, command in commands.items():
            row, identity = run(command)
            if not samples[name]:
                print(identity)
            samples[name].append(row)
    print(f"\nMedian of {args.runs} runs, MiB/s (MB/s labels in original tools); ratio = zigfitsio / CFITSIO")
    print("workload                     zigfitsio     CFITSIO     ratio")
    for key in samples["zigfitsio"][0]:
        zig = statistics.median(row[key] for row in samples["zigfitsio"])
        c = statistics.median(row[key] for row in samples["CFITSIO"])
        print(f"{' '.join(key):28} {zig:10.1f} {c:11.1f} {zig / c:9.2f}x")
    print("Informational: no performance threshold is a CI or release gate.")


if __name__ == "__main__":
    main()
