#!/usr/bin/env python3
"""Compare header benchmark JSON files against confidence-bound speedup rules."""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
from pathlib import Path
import random
import statistics
import sys
from typing import Any


DEFAULT_CONFIG = Path(__file__).with_name("bench_header_thresholds.json")


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def bootstrap_speedup(
    baseline: list[float], candidate: list[float], confidence: float, resamples: int, seed: int
) -> tuple[float, float, float]:
    rng = random.Random(seed)
    estimates = []
    for _ in range(resamples):
        left = [baseline[rng.randrange(len(baseline))] for _ in baseline]
        right = [candidate[rng.randrange(len(candidate))] for _ in candidate]
        estimates.append(statistics.median(left) / statistics.median(right))
    tail = (1.0 - confidence) / 2.0
    return (
        statistics.median(baseline) / statistics.median(candidate),
        percentile(estimates, tail),
        percentile(estimates, 1.0 - tail),
    )


def load_documents(paths: list[Path]) -> tuple[dict[tuple[str, str, str], dict[str, Any]], list[str]]:
    index: dict[tuple[str, str, str], dict[str, Any]] = {}
    warnings = []
    for path in paths:
        document = json.loads(path.read_text(encoding="utf-8"))
        if document.get("schema_version") != 1 or document.get("benchmark") != "header-binding-ab":
            raise ValueError(f"{path}: not a header-binding-ab schema v1 document")
        runtime = document.get("runtime", {}).get("id")
        if not runtime:
            raise ValueError(f"{path}: missing runtime.id")
        for case in document.get("cases", []):
            samples = case.get("samples_ns_per_op")
            if not samples or any(not isinstance(value, (int, float)) or value <= 0 for value in samples):
                raise ValueError(f"{path}: invalid samples for {case.get('group')}/{case.get('variant')}")
            key = (runtime, case["group"], case["variant"])
            if key in index:
                prior = index[key]
                if prior.get("fixture_sha256") != case.get("fixture_sha256"):
                    raise ValueError(f"{path}: fixture mismatch while merging {key}")
                prior["samples_ns_per_op"].extend(samples)
                warnings.append(f"merged duplicate case {runtime} {case['group']} {case['variant']}")
            else:
                index[key] = dict(case)
                index[key]["samples_ns_per_op"] = list(samples)
    return index, warnings


def compare(
    index: dict[tuple[str, str, str], dict[str, Any]], config: dict[str, Any], require_candidates: bool,
    resamples_override: int | None,
) -> dict[str, Any]:
    defaults = config.get("defaults", {})
    confidence = float(defaults.get("confidence", 0.95))
    resamples = int(resamples_override or defaults.get("bootstrap_resamples", 5000))
    decision = defaults.get("decision", "lower_bound")
    results = []
    seen: set[tuple[str, str, str, str]] = set()
    for rule_index, rule in enumerate(config.get("rules", [])):
        runtime_pattern = rule.get("runtime", "*")
        group_pattern = rule.get("group", "*")
        baseline_variant = rule["baseline"]
        candidate_variant = rule["candidate"]
        minimum = float(rule["min_speedup"])
        for runtime, group, variant in sorted(index):
            if variant != baseline_variant or not fnmatch.fnmatchcase(runtime, runtime_pattern):
                continue
            if not fnmatch.fnmatchcase(group, group_pattern):
                continue
            identity = (runtime, group, baseline_variant, candidate_variant)
            if identity in seen:
                continue
            seen.add(identity)
            baseline = index[(runtime, group, baseline_variant)]
            candidate = index.get((runtime, group, candidate_variant))
            required = require_candidates or bool(rule.get("required", False))
            record: dict[str, Any] = {
                "runtime": runtime, "group": group, "baseline": baseline_variant,
                "candidate": candidate_variant, "min_speedup": minimum, "rule_index": rule_index,
            }
            if candidate is None:
                record.update(status="fail" if required else "skip", reason="candidate case unavailable")
                results.append(record)
                continue
            if baseline.get("fixture_sha256") != candidate.get("fixture_sha256"):
                record.update(status="fail", reason="baseline and candidate fixture hashes differ")
                results.append(record)
                continue
            key = f"{runtime}\0{group}\0{baseline_variant}\0{candidate_variant}".encode()
            seed = int.from_bytes(hashlib.sha256(key).digest()[:8], "big")
            point, lower, upper = bootstrap_speedup(
                baseline["samples_ns_per_op"], candidate["samples_ns_per_op"],
                float(rule.get("confidence", confidence)), resamples, seed,
            )
            tested = lower if rule.get("decision", decision) == "lower_bound" else point
            record.update(
                status="pass" if tested >= minimum else "fail",
                speedup=point, confidence_lower=lower, confidence_upper=upper,
                baseline_median_ns=statistics.median(baseline["samples_ns_per_op"]),
                candidate_median_ns=statistics.median(candidate["samples_ns_per_op"]),
                decision_value=tested,
            )
            results.append(record)
    counts = {status: sum(result["status"] == status for result in results) for status in ("pass", "fail", "skip")}
    return {
        "schema_version": 1, "comparison": "header-binding-thresholds",
        "config": str(config.get("name", "unnamed")), "bootstrap_resamples": resamples,
        "summary": counts, "results": results,
    }


def render_text(report: dict[str, Any], warnings: list[str]) -> str:
    lines = []
    for warning in warnings:
        lines.append(f"WARN  {warning}")
    for result in report["results"]:
        label = result["status"].upper().ljust(5)
        prefix = f"{label} {result['runtime']} {result['group']}: {result['baseline']} -> {result['candidate']}"
        if "speedup" in result:
            lines.append(
                f"{prefix} {result['speedup']:.3f}x "
                f"(CI {result['confidence_lower']:.3f}..{result['confidence_upper']:.3f}, "
                f"required {result['min_speedup']:.3f}x)"
            )
        else:
            lines.append(f"{prefix} ({result['reason']})")
    summary = report["summary"]
    lines.append(f"summary: {summary['pass']} passed, {summary['fail']} failed, {summary['skip']} skipped")
    return "\n".join(lines) + "\n"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs", nargs="+", type=Path)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--require-candidates", action="store_true")
    parser.add_argument("--bootstrap-resamples", type=int)
    parser.add_argument("--format", choices=("text", "json"), default="text")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.bootstrap_resamples is not None and args.bootstrap_resamples < 100:
        parser.error("bootstrap-resamples must be at least 100")
    return args


def main() -> int:
    args = parse_args()
    config = json.loads(args.config.read_text(encoding="utf-8"))
    index, warnings = load_documents(args.inputs)
    report = compare(index, config, args.require_candidates, args.bootstrap_resamples)
    encoded = json.dumps(report, indent=2, sort_keys=True) + "\n" if args.format == "json" else render_text(report, warnings)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded, encoding="utf-8")
    else:
        sys.stdout.write(encoded)
    return 1 if report["summary"]["fail"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
