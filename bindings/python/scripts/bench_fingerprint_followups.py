#!/usr/bin/env python3
"""Opt-in proof for Python's core-owned fingerprints.

    zig build capi -Doptimize=ReleaseFast
    PYTHONPATH=bindings/python/src uv run --no-project --with numpy \
        python bindings/python/scripts/bench_fingerprint_followups.py

Set ZIGFITSIO_BENCH_SAMPLES to change the default 15 measured pairs.
"""

from __future__ import annotations

from hashlib import blake2b
import math
import os
from pathlib import Path
import platform
from statistics import median
import sys
from time import perf_counter_ns

import numpy as np

if sys.platform == "darwin":
    _subdir, _libname = "lib", "libzigfitsio_capi.dylib"
elif sys.platform == "win32":
    _subdir, _libname = "bin", "zigfitsio_capi.dll"
else:
    _subdir, _libname = "lib", "libzigfitsio_capi.so"
_built_library = Path(__file__).resolve().parents[3] / "zig-out" / _subdir / _libname
if not _built_library.exists():
    raise SystemExit("run `zig build capi -Doptimize=ReleaseFast` before this benchmark")
os.environ["ZIGFITSIO_LIBRARY"] = str(_built_library)

from zigfitsio.core import _col_fp, _ndarray_fp


SAMPLES = int(os.environ.get("ZIGFITSIO_BENCH_SAMPLES", "15"))
if SAMPLES < 3:
    raise ValueError("ZIGFITSIO_BENCH_SAMPLES must be an integer >= 3")

_sink = 0


def _legacy_hash_array_into(digest, arr) -> None:
    arr = np.asarray(arr)
    if not arr.nbytes:
        return
    if arr.flags.c_contiguous:
        digest.update(memoryview(arr).cast("B"))
        return
    chunks = np.nditer(
        arr,
        flags=["external_loop", "buffered", "zerosize_ok"],
        op_flags=[["readonly", "contig"]],
        order="C",
        buffersize=max(1, (64 * 1024) // max(arr.dtype.itemsize, 1)),
    )
    for chunk in chunks:
        digest.update(memoryview(chunk).cast("B"))


def _legacy_ndarray_fp(arr) -> bytes:
    digest = blake2b(digest_size=16)
    _legacy_hash_array_into(digest, arr)
    return digest.digest()


def _legacy_col_fp(col) -> bytes:
    if col.dtype == object:
        digest = blake2b(digest_size=16)
        for cell in col:
            arr = np.asarray(cell)
            digest.update(int(arr.nbytes).to_bytes(8, "little"))
            _legacy_hash_array_into(digest, arr)
        return digest.digest()
    return _legacy_ndarray_fp(col)


def _percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    return ordered[math.ceil(len(ordered) * fraction) - 1]


def _timed(fn) -> float:
    global _sink
    start = perf_counter_ns()
    digest = fn()
    elapsed_ms = (perf_counter_ns() - start) / 1e6
    _sink ^= int.from_bytes(digest[:8], "little")
    return elapsed_ms


def _compare(name: str, logical_bytes: int, legacy, core) -> tuple[str, ...]:
    global _sink
    for _ in range(3):
        for fn in (legacy, core):
            digest = fn()
            _sink ^= int.from_bytes(digest[:8], "little")

    legacy_times: list[float] = []
    core_times: list[float] = []
    for i in range(SAMPLES):
        if i % 2 == 0:
            first, second = (legacy, legacy_times), (core, core_times)
        else:
            first, second = (core, core_times), (legacy, legacy_times)
        first[1].append(_timed(first[0]))
        second[1].append(_timed(second[0]))

    legacy_median = median(legacy_times)
    core_median = median(core_times)
    return (
        name,
        f"{logical_bytes / 1048576:.2f}",
        f"{legacy_median:.3f}",
        f"{_percentile(legacy_times, 0.95):.3f}",
        f"{core_median:.3f}",
        f"{_percentile(core_times, 0.95):.3f}",
        f"{legacy_median / core_median:.2f}x",
    )


def _vla_fixture() -> np.ndarray:
    lengths = (0, 1, 16, 256, 4096)
    cells = np.empty(2048, dtype=object)
    for i in range(cells.size):
        length = lengths[i % len(lengths)]
        base = np.arange(length * 2, dtype="i4")
        cells[i] = base[::2] if i % 4 == 0 else base[:length]
    return cells


def main() -> None:
    contiguous = np.arange(8 * 1024 * 1024, dtype="u1")
    transposed = contiguous.reshape(2048, 4096).T
    vlas = _vla_fixture()

    rows = [
        _compare(
            "8 MiB contiguous u1",
            contiguous.nbytes,
            lambda: _legacy_ndarray_fp(contiguous),
            lambda: _ndarray_fp(contiguous),
        ),
        _compare(
            "8 MiB transposed u1",
            transposed.nbytes,
            lambda: _legacy_ndarray_fp(transposed),
            lambda: _ndarray_fp(transposed),
        ),
        _compare(
            "VLA: 2048 mixed cells",
            sum(8 + np.asarray(cell).nbytes for cell in vlas),
            lambda: _legacy_col_fp(vlas),
            lambda: _col_fp(vlas),
        ),
    ]

    print(
        f"Python fingerprint proof ({SAMPLES} alternating samples, "
        f"Python {platform.python_version()}, NumPy {np.__version__})"
    )
    headers = ("workload", "MiB", "legacy med ms", "legacy p95 ms", "core med ms", "core p95 ms", "speedup")
    widths = [max(len(headers[i]), *(len(row[i]) for row in rows)) for i in range(len(headers))]
    print("  ".join(value.ljust(widths[i]) for i, value in enumerate(headers)))
    print("  ".join("-" * width for width in widths))
    for row in rows:
        print("  ".join(value.ljust(widths[i]) for i, value in enumerate(row)))

    if _sink == -1:
        print("")


if __name__ == "__main__":
    main()
