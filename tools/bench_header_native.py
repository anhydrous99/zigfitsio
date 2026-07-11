#!/usr/bin/env python3
"""A/B benchmark for the Python header binding and the proposed Zig header ABI.

The legacy path is always available.  Candidate cases are added only when all v1
snapshot/apply symbols are exported by the loaded C library.  The tool deliberately
loads only ``lowlevel.py`` and ``header.py`` from the source tree, so the harness itself
has no third-party Python dependency.
"""

from __future__ import annotations

import argparse
import ctypes as c
import gc
import hashlib
import importlib
import json
import os
from pathlib import Path
import platform
import statistics
import sys
import time
import types
from typing import Any, Callable


ROOT = Path(__file__).resolve().parents[1]
CARD = 80
BLOCK = 2880
SCHEMA_VERSION = 1


def _csv_ints(text: str) -> list[int]:
    values = [int(part.strip()) for part in text.split(",") if part.strip()]
    if not values or any(value < 0 for value in values):
        raise argparse.ArgumentTypeError("expected comma-separated non-negative integers")
    return values


def _csv_names(text: str) -> list[str]:
    values = [part.strip() for part in text.split(",") if part.strip()]
    if not values:
        raise argparse.ArgumentTypeError("expected a comma-separated list")
    return values


def _card(text: str) -> bytes:
    encoded = text.encode("ascii")
    if len(encoded) > CARD:
        raise ValueError(f"card is {len(encoded)} bytes: {text!r}")
    return encoded.ljust(CARD, b" ")


def _value_card(keyword: str, literal: str, comment: str = "") -> bytes:
    body = f"{keyword:<8}= {literal:>20}"
    if comment:
        body += f" / {comment}"
    return _card(body)


def make_fixture(physical_cards: int, profile: str, tail_bytes: int) -> tuple[bytes, list[bytes]]:
    """Return deterministic FITS bytes and standard user keys safe for update tests."""
    if physical_cards < 6:
        raise ValueError("a 1-D primary fixture needs at least 6 physical cards including END")
    cards = [
        _value_card("SIMPLE", "T"),
        _value_card("BITPIX", "8"),
        _value_card("NAXIS", "1"),
        _value_card("NAXIS1", str(tail_bytes)),
        _value_card("EXTEND", "T"),
    ]
    edit_keys: list[bytes] = []
    remaining = physical_cards - len(cards) - 1
    item = 0
    while remaining:
        key = f"K{item:07d}"
        if profile == "scalar":
            cards.append(_value_card(key, str(item), f"scalar {item}"))
            edit_keys.append(key.encode("ascii"))
            remaining -= 1
        elif profile == "mixed":
            kind = item % 7
            if kind == 0:
                cards.append(_value_card(key, str(item), "integer"))
                edit_keys.append(key.encode("ascii"))
            elif kind == 1:
                cards.append(_value_card(key, f"{item + 0.25:.6E}", "float"))
                edit_keys.append(key.encode("ascii"))
            elif kind == 2:
                cards.append(_value_card(key, "T" if item % 2 else "F", "logical"))
                edit_keys.append(key.encode("ascii"))
            elif kind == 3:
                cards.append(_value_card(key, f"'value-{item:07d}'", "string"))
                edit_keys.append(key.encode("ascii"))
            elif kind == 4:
                cards.append(_card(f"COMMENT deterministic commentary {item:07d}"))
            elif kind == 5:
                cards.append(_card(f"HISTORY deterministic history {item:07d}"))
            else:
                cards.append(_card(f"HIERARCH BENCH GROUP ITEM {item:07d} = {item} / hierarch"))
            remaining -= 1
        elif profile == "continuation":
            if remaining >= 2:
                cards.append(_value_card(key, f"'segment-{item:07d}-aaaaaaaaaaaaaaaaaaaaaaaa&'"))
                cards.append(_card("CONTINUE  'bbbbbbbbbbbbbbbbbbbbbbbb' / folded long string"))
                edit_keys.append(key.encode("ascii"))
                remaining -= 2
            else:
                cards.append(_value_card(key, str(item), "single-card remainder"))
                edit_keys.append(key.encode("ascii"))
                remaining -= 1
        else:
            raise ValueError(f"unknown profile {profile!r}")
        item += 1
    cards.append(_card("END"))
    header = b"".join(cards)
    header += b" " * ((-len(header)) % BLOCK)
    data = bytes(((index * 17 + 3) & 0xFF) for index in range(tail_bytes))
    data += b"\0" * ((-len(data)) % BLOCK)
    return header + data, edit_keys


def load_binding() -> tuple[Any, Callable[[list[bytes]], list[Any]]]:
    """Import the two dependency-free binding modules without executing package __init__."""
    # A source checkout can also contain an older wheel-layout library next to lowlevel.py, and
    # the normal loader intentionally prefers that bundled artifact.  A repository benchmark must
    # instead measure the optimized artifact it just built.  Keep an explicit caller override.
    library_name = (
        "libzigfitsio_capi.dylib" if sys.platform == "darwin"
        else "zigfitsio_capi.dll" if sys.platform == "win32"
        else "libzigfitsio_capi.so"
    )
    library_dir = "bin" if sys.platform == "win32" else "lib"
    built_library = ROOT / "zig-out" / library_dir / library_name
    if "ZIGFITSIO_LIBRARY" not in os.environ and built_library.exists():
        os.environ["ZIGFITSIO_LIBRARY"] = str(built_library)
    package_dir = ROOT / "bindings" / "python" / "src" / "zigfitsio"
    package = types.ModuleType("zigfitsio")
    package.__path__ = [str(package_dir)]
    package.__package__ = "zigfitsio"
    sys.modules["zigfitsio"] = package
    lowlevel = importlib.import_module("zigfitsio.lowlevel")
    header = importlib.import_module("zigfitsio.header")
    return lowlevel, header.parse_cards


class SnapshotInfo(c.Structure):
    _fields_ = [(name, c.c_uint64) for name in (
        "revision", "logical_count", "physical_count", "arena_bytes", "raw_bytes", "flags"
    )]


class HeaderEntry(c.Structure):
    _fields_ = [
        ("kind", c.c_uint32), ("value_type", c.c_uint32),
        ("flags", c.c_uint32), ("reserved", c.c_uint32),
        ("physical_first", c.c_uint64), ("physical_count", c.c_uint64),
        ("keyword_off", c.c_uint64), ("keyword_len", c.c_uint64),
        ("value_off", c.c_uint64), ("value_len", c.c_uint64),
        ("comment_off", c.c_uint64), ("comment_len", c.c_uint64),
        ("int_value", c.c_int64), ("float_value", c.c_double),
    ]


class HeaderOp(c.Structure):
    _fields_ = [
        ("opcode", c.c_uint32), ("value_type", c.c_uint32),
        ("flags", c.c_uint32), ("reserved", c.c_uint32),
        ("name_off", c.c_uint64), ("name_len", c.c_uint64),
        ("value_off", c.c_uint64), ("value_len", c.c_uint64),
        ("comment_off", c.c_uint64), ("comment_len", c.c_uint64),
        ("int_value", c.c_int64), ("float_value", c.c_double),
        ("position", c.c_int64),
    ]


class ApplyOpts(c.Structure):
    _fields_ = [("expected_revision", c.c_uint64), ("flags", c.c_uint32), ("reserved", c.c_uint32)]


class ApplyResult(c.Structure):
    _fields_ = [(name, c.c_uint64) for name in (
        "new_revision", "failed_op", "cards_before", "cards_after"
    )]


def validate_struct_layouts() -> None:
    """Tripwire the tool-side ctypes layouts against bindings/c/zigfitsio.h V1."""
    expected = {
        SnapshotInfo: (48, {"revision": 0, "flags": 40}),
        HeaderEntry: (96, {"kind": 0, "physical_first": 16, "int_value": 80, "float_value": 88}),
        HeaderOp: (88, {"opcode": 0, "name_off": 16, "int_value": 64, "float_value": 72, "position": 80}),
        ApplyOpts: (16, {"expected_revision": 0, "flags": 8, "reserved": 12}),
        ApplyResult: (32, {"new_revision": 0, "cards_after": 24}),
    }
    for struct, (size, offsets) in expected.items():
        actual_size = c.sizeof(struct)
        if actual_size != size:
            raise RuntimeError(f"{struct.__name__} ABI size is {actual_size}, expected {size}")
        for field, offset in offsets.items():
            actual_offset = getattr(struct, field).offset
            if actual_offset != offset:
                raise RuntimeError(
                    f"{struct.__name__}.{field} ABI offset is {actual_offset}, expected {offset}"
                )


class Candidate:
    """ctypes adapter kept in tools/ so an old Python binding can probe a new core."""

    QUERY = "zf_header_snapshot_query_v1"
    FILL = "zf_header_snapshot_fill_v1"
    APPLY = "zf_header_apply_v1"

    def __init__(self, ll: Any, layout: str):
        self.ll = ll
        self.layout = layout
        self.query = self._symbol(self.QUERY)
        self.fill = self._symbol(self.FILL)
        self.apply_fn = self._symbol(self.APPLY)
        self.snapshot_available = self.query is not None and self.fill is not None
        self.apply_available = self.apply_fn is not None
        if self.snapshot_available:
            prefix = [ll.VOID, ll.U64] if layout == "hdu-index" else [ll.VOID]
            self.query.restype = ll.INT
            self.query.argtypes = prefix + [ll.U32, c.POINTER(SnapshotInfo)]
            self.fill.restype = ll.INT
            self.fill.argtypes = prefix + [
                ll.U32, ll.U64, c.POINTER(HeaderEntry), ll.SZ,
                ll.VOID, ll.SZ, ll.VOID, ll.SZ, c.POINTER(SnapshotInfo),
            ]
        if self.apply_available:
            prefix = [ll.VOID, ll.U64] if layout == "hdu-index" else [ll.VOID]
            self.apply_fn.restype = ll.INT
            self.apply_fn.argtypes = prefix + [
                c.POINTER(ApplyOpts), c.POINTER(HeaderOp), ll.SZ,
                ll.VOID, ll.SZ, c.POINTER(ApplyResult),
            ]

    def _symbol(self, name: str) -> Any | None:
        try:
            return getattr(self.ll.lib, name)
        except AttributeError:
            return None

    def _prefix(self, handle: c.c_void_p) -> list[Any]:
        return [handle, c.c_uint64(1)] if self.layout == "hdu-index" else [handle]

    def snapshot(self, handle: c.c_void_p) -> tuple[SnapshotInfo, Any, bytes]:
        info = SnapshotInfo()
        self.ll.check(self.query(*self._prefix(handle), 0, c.byref(info)))
        entries = (HeaderEntry * int(info.logical_count))()
        arena = (c.c_uint8 * int(info.arena_bytes))()
        out = SnapshotInfo()
        self.ll.check(self.fill(
            *self._prefix(handle), 0, info.revision,
            entries, info.logical_count, arena, info.arena_bytes,
            None, 0, c.byref(out),
        ))
        return out, entries, bytes(arena)

    @staticmethod
    def materialize(snapshot: tuple[SnapshotInfo, Any, bytes]) -> list[tuple[Any, ...]]:
        info, entries, arena = snapshot
        result = []
        for entry in entries[: int(info.logical_count)]:
            keyword = arena[entry.keyword_off : entry.keyword_off + entry.keyword_len].decode("utf-8", "replace")
            comment = arena[entry.comment_off : entry.comment_off + entry.comment_len].decode("utf-8", "replace")
            if entry.value_type == 0 and entry.value_len:
                value: Any = arena[entry.value_off : entry.value_off + entry.value_len].decode("utf-8", "replace")
            elif entry.value_type == 2:
                value: Any = bool(entry.int_value)
            elif entry.value_type == 3:
                value = int(entry.int_value)
            elif entry.value_type == 5:
                value = float(entry.float_value)
            elif entry.value_type in (4, 6, 7):
                value = arena[entry.value_off : entry.value_off + entry.value_len].decode("utf-8", "replace")
            else:
                value = None
            result.append((keyword, value, comment, int(entry.kind), int(entry.flags)))
        return result

    def make_apply(self, handle: c.c_void_p, keys: list[bytes]) -> Callable[[], int]:
        arena_bytes = b"".join(keys)
        arena = (c.c_uint8 * len(arena_bytes)).from_buffer_copy(arena_bytes)
        ops = (HeaderOp * len(keys))()
        offset = 0
        for index, key in enumerate(keys):
            ops[index].opcode = 1       # ZF_HEADER_OP_UPSERT
            ops[index].value_type = 3   # ZF_HEADER_VALUE_INT64
            ops[index].name_off = offset
            ops[index].name_len = len(key)
            ops[index].position = -1
            offset += len(key)
        counter = 0

        def apply() -> int:
            nonlocal counter
            counter += 1
            for index in range(len(keys)):
                ops[index].int_value = counter + index
            result = ApplyResult()
            opts = ApplyOpts(0, 0, 0)
            self.ll.check(self.apply_fn(
                *self._prefix(handle), c.byref(opts), ops, len(keys),
                arena, len(arena_bytes), c.byref(result),
            ))
            return int(result.new_revision ^ result.cards_after)

        return apply


def choose_layout(requested: str) -> str:
    if requested != "auto":
        return requested
    header = ROOT / "bindings" / "c" / "zigfitsio.h"
    try:
        text = header.read_text(encoding="utf-8")
        start = text.index("zf_header_snapshot_query_v1")
        declaration = text[start : start + 240]
        return "hdu-index" if "hdu_index" in declaration else "selected-hdu"
    except (OSError, ValueError):
        return "hdu-index"


def open_memory(ll: Any, data: bytes, mode: int) -> c.c_void_p:
    handle = c.c_void_p()
    ll.check(ll.lib.zf_open_memory(data, len(data), mode, None, c.byref(handle)))
    ll.check(ll.lib.zf_select(handle, 1))
    return handle


def legacy_raw_reader(ll: Any, handle: c.c_void_p) -> Callable[[], list[bytes]]:
    def read() -> list[bytes]:
        count = c.c_long()
        ll.check(ll.lib.zf_card_count(handle, c.byref(count)))
        buf = c.create_string_buffer(CARD)
        raws = []
        for index in range(count.value):
            ll.check(ll.lib.zf_read_card(handle, index, buf))
            raws.append(buf.raw[:CARD])
        return raws

    return read


def calibrate(fn: Callable[[], Any], target_ns: int) -> tuple[int, int]:
    loops = 1
    checksum = 0
    while True:
        start = time.perf_counter_ns()
        for _ in range(loops):
            value = fn()
            checksum ^= len(value) if hasattr(value, "__len__") else int(value or 0)
        elapsed = time.perf_counter_ns() - start
        if elapsed >= target_ns or loops >= (1 << 20):
            return loops, checksum
        loops *= max(2, min(16, (target_ns + max(elapsed, 1) - 1) // max(elapsed, 1)))


def bench_interleaved(
    variants: dict[str, Callable[[], Any]], samples: int, warmups: int, target_ns: int
) -> dict[str, tuple[list[float], int, int]]:
    """Measure variants in AB/BA order and return samples, loops/sample, checksum."""
    loops: dict[str, int] = {}
    checksums = {name: 0 for name in variants}
    for _ in range(warmups):
        for name, fn in variants.items():
            value = fn()
            checksums[name] ^= len(value) if hasattr(value, "__len__") else int(value or 0)
    for name, fn in variants.items():
        loops[name], extra = calibrate(fn, target_ns)
        checksums[name] ^= extra
    measured = {name: [] for name in variants}
    names = list(variants)
    for sample_index in range(samples):
        order = names if sample_index % 2 == 0 else list(reversed(names))
        for name in order:
            start = time.perf_counter_ns()
            for _ in range(loops[name]):
                value = variants[name]()
                checksums[name] ^= len(value) if hasattr(value, "__len__") else int(value or 0)
            measured[name].append((time.perf_counter_ns() - start) / loops[name])
    return {name: (measured[name], loops[name], checksums[name]) for name in names}


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def case_result(
    group: str, variant: str, params: dict[str, Any], measured: tuple[list[float], int, int],
    ffi_calls: int, fixture_hash: str,
) -> dict[str, Any]:
    samples, loops, checksum = measured
    median = statistics.median(samples)
    return {
        "group": group,
        "variant": variant,
        "operation": group.split("/", 1)[0],
        "params": params,
        "fixture_sha256": fixture_hash,
        "ffi_calls_per_op": ffi_calls,
        "iterations_per_sample": loops,
        "samples_ns_per_op": samples,
        "median_ns": median,
        "mad_ns": statistics.median(abs(value - median) for value in samples),
        "p95_ns": percentile(samples, 0.95),
        "checksum": checksum,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cards", type=_csv_ints, default=_csv_ints("6,36,360"))
    parser.add_argument("--profiles", type=_csv_names, default=_csv_names("scalar,mixed,continuation"))
    parser.add_argument("--tail-bytes", type=_csv_ints, default=_csv_ints("0"))
    parser.add_argument("--edits", type=_csv_ints, default=_csv_ints("1,8,32"))
    parser.add_argument("--operations", type=_csv_names, default=_csv_names("ffi,read,apply"))
    parser.add_argument("--samples", type=int, default=12)
    parser.add_argument("--warmups", type=int, default=3)
    parser.add_argument("--target-ms", type=float, default=50.0)
    parser.add_argument("--candidate-layout", choices=("auto", "hdu-index", "selected-hdu"), default="auto")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.samples < 1 or args.warmups < 0 or args.target_ms <= 0:
        parser.error("samples must be positive, warmups non-negative, and target-ms positive")
    unknown = set(args.profiles) - {"scalar", "mixed", "continuation"}
    if unknown:
        parser.error(f"unknown profiles: {', '.join(sorted(unknown))}")
    unknown = set(args.operations) - {"ffi", "read", "apply"}
    if unknown:
        parser.error(f"unknown operations: {', '.join(sorted(unknown))}")
    return args


def main() -> int:
    args = parse_args()
    validate_struct_layouts()
    ll, parse_cards = load_binding()
    layout = choose_layout(args.candidate_layout)
    candidate = Candidate(ll, layout)
    cases: list[dict[str, Any]] = []
    skips: list[dict[str, Any]] = []
    target_ns = int(args.target_ms * 1_000_000)
    gc_was_enabled = gc.isenabled()
    gc.disable()
    try:
        if "ffi" in args.operations:
            measured = bench_interleaved({"legacy_noop": ll.lib.zf_last_status}, args.samples, args.warmups, target_ns)
            cases.append(case_result("ffi/noop", "legacy_noop", {}, measured["legacy_noop"], 1, ""))

        for profile in args.profiles:
            for physical_cards in args.cards:
                for tail_bytes in args.tail_bytes:
                    fixture, edit_keys = make_fixture(physical_cards, profile, tail_bytes)
                    fixture_hash = hashlib.sha256(fixture).hexdigest()
                    params = {"physical_cards": physical_cards, "profile": profile, "tail_bytes": tail_bytes}

                    if "read" in args.operations:
                        handle = open_memory(ll, fixture, ll.READONLY)
                        raw_read = legacy_raw_reader(ll, handle)
                        cached_raws = raw_read()
                        read_variants: dict[str, Callable[[], Any]] = {
                            "legacy_abi": raw_read,
                            "legacy_parse": lambda raws=cached_raws: parse_cards(raws),
                            "legacy_e2e": lambda read=raw_read: parse_cards(read()),
                        }
                        candidate_handle = None
                        if candidate.snapshot_available:
                            candidate_handle = open_memory(ll, fixture, ll.READONLY)
                            candidate_probe = candidate.materialize(candidate.snapshot(candidate_handle))
                            legacy_probe = parse_cards(cached_raws)
                            if len(candidate_probe) != len(legacy_probe):
                                raise RuntimeError(
                                    f"snapshot logical count mismatch for {profile}/{physical_cards}: "
                                    f"candidate={len(candidate_probe)}, legacy={len(legacy_probe)}"
                                )
                            candidate_values = [(row[0], row[1], row[2]) for row in candidate_probe]
                            legacy_values = [(row.keyword, row.value, row.comment) for row in legacy_probe]
                            if candidate_values != legacy_values:
                                mismatch = next(
                                    index for index, pair in enumerate(zip(candidate_values, legacy_values))
                                    if pair[0] != pair[1]
                                )
                                raise RuntimeError(
                                    f"snapshot semantic mismatch for {profile}/{physical_cards} at "
                                    f"logical entry {mismatch}: candidate={candidate_values[mismatch]!r}, "
                                    f"legacy={legacy_values[mismatch]!r}"
                                )
                            read_variants["snapshot_abi"] = lambda h=candidate_handle: candidate.snapshot(h)
                            read_variants["snapshot_e2e"] = lambda h=candidate_handle: candidate.materialize(candidate.snapshot(h))
                        measured = bench_interleaved(read_variants, args.samples, args.warmups, target_ns)
                        group = f"read/{profile}/cards-{physical_cards:04d}/tail-{tail_bytes}"
                        calls = {
                            "legacy_abi": 1 + physical_cards, "legacy_parse": 0,
                            "legacy_e2e": 1 + physical_cards, "snapshot_abi": 2, "snapshot_e2e": 2,
                        }
                        for variant in read_variants:
                            cases.append(case_result(group, variant, params, measured[variant], calls[variant], fixture_hash))
                        ll.lib.zf_close(handle)
                        if candidate_handle is not None:
                            ll.lib.zf_close(candidate_handle)

                    if "apply" in args.operations:
                        for edit_count in args.edits:
                            if edit_count == 0 or len(edit_keys) < edit_count:
                                skips.append({
                                    "group": f"apply/{profile}/cards-{physical_cards:04d}/edits-{edit_count}/tail-{tail_bytes}",
                                    "reason": f"fixture has {len(edit_keys)} editable standard keys",
                                })
                                continue
                            keys = edit_keys[:edit_count]
                            handle = open_memory(ll, fixture, ll.READWRITE)
                            counter = 0

                            def legacy_apply(h: c.c_void_p = handle, ks: list[bytes] = keys) -> int:
                                nonlocal counter
                                counter += 1
                                for index, key in enumerate(ks):
                                    ll.check(ll.lib.zf_write_key_lng(h, key, len(key), counter + index, None, 0))
                                return counter

                            apply_variants: dict[str, Callable[[], Any]] = {"legacy_individual": legacy_apply}
                            candidate_handle = None
                            if candidate.apply_available:
                                candidate_handle = open_memory(ll, fixture, ll.READWRITE)
                                apply_variants["batch_apply"] = candidate.make_apply(candidate_handle, keys)
                            measured = bench_interleaved(apply_variants, args.samples, args.warmups, target_ns)
                            group = f"apply/{profile}/cards-{physical_cards:04d}/edits-{edit_count}/tail-{tail_bytes}"
                            edit_params = {**params, "edits": edit_count}
                            for variant in apply_variants:
                                calls = edit_count if variant == "legacy_individual" else 1
                                cases.append(case_result(group, variant, edit_params, measured[variant], calls, fixture_hash))
                            ll.lib.zf_close(handle)
                            if candidate_handle is not None:
                                ll.lib.zf_close(candidate_handle)
    finally:
        if gc_was_enabled:
            gc.enable()

    missing_snapshot = [name for name in (Candidate.QUERY, Candidate.FILL) if candidate._symbol(name) is None]
    missing_apply = [] if candidate.apply_available else [Candidate.APPLY]
    document = {
        "schema_version": SCHEMA_VERSION,
        "benchmark": "header-binding-ab",
        "runtime": {
            "id": "python-native", "name": "python", "version": platform.python_version(),
            "platform": sys.platform, "machine": platform.machine(),
        },
        "artifact": {"zigfitsio_version": ll.version(), "library": getattr(ll.lib, "_name", "unknown")},
        "config": {
            "cards": args.cards, "profiles": args.profiles, "tail_bytes": args.tail_bytes,
            "edits": args.edits, "operations": args.operations, "samples": args.samples,
            "warmups": args.warmups, "target_ms": args.target_ms,
        },
        "capabilities": {
            "candidate_layout": layout,
            "adapter": "ctypes-binding",
            "snapshot_v1": {"available": candidate.snapshot_available, "missing_symbols": missing_snapshot},
            "apply_v1": {"available": candidate.apply_available, "missing_symbols": missing_apply},
        },
        "cases": cases,
        "skips": skips,
    }
    encoded = json.dumps(document, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded, encoding="utf-8")
        print(f"wrote {len(cases)} cases to {args.output}", file=sys.stderr)
    else:
        sys.stdout.write(encoded)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
