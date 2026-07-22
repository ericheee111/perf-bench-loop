#!/usr/bin/env python3
"""
validate-asv-selection.py — Pre-check ASV benchmark selectors before launch.

THE PROBLEM THIS PREVENTS:
  When multiple -b selectors are passed to ASV, a typo'd or CR-contaminated
  selector silently matches zero benchmarks. ASV runs the other selectors
  to completion with exit 0, and the shared results file retains stale data
  from a previous run for the zero-matched benchmark. compare-asv.py then
  reads that stale data as if it were fresh, producing a valid-looking but
  false comparison table.

WHAT IT DOES:
  1. Loads benchmark metadata from benchmarks.json (ASV's metadata cache).
  2. Parses all -b / --bench selectors from the ASV command.
  3. For EACH selector individually, applies ASV's matching rules:
     - Expand parameter combinations for each benchmark.
     - Construct case labels: benchmark.name(param1, param2, ...)
     - Apply re.search(selector, case_label) per case.
     - Only cases that match are selected.
  4. Any selector with zero matches → exit 1 (fail before launch).
  5. Invalid regex → exit 1 (ASV uses re.search directly; no literal fallback).
  6. Writes expected-cases.jsonl to the output file path.
  7. Strips trailing CR from selectors before matching (defensive against
     Windows CRLF contamination).

  This script should be deployed to and run on the benchmark machine
  (same filesystem layer as ASV), not locally.

Usage:
    validate-asv-selection.py --benchmarks-file <benchmarks.json> \\
        --output-file <expected-cases.jsonl> \\
        [-- asv-subcommand-and-flags...]

Exit status:
    0  All selectors match at least one case. expected-cases.jsonl written.
    1  At least one selector matched zero cases, or invalid regex.
    2  Could not load benchmarks.json or other setup error.
    64 Usage error.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from itertools import product
from pathlib import Path
from typing import Any

# Import shared expected-cases functions
sys.path.insert(0, str(Path(__file__).resolve().parent))
from expected_cases import write_expected_cases, format_case_label


# ---------------------------------------------------------------------------
# Selector parsing
# ---------------------------------------------------------------------------

def extract_selectors(argv: list[str]) -> list[str]:
    """Extract all -b VALUE and --bench VALUE and --bench=VALUE from argv.

    Returns a list of selector strings (may contain duplicates).
    Returns empty list if no -b/--bench found (meaning "all benchmarks").
    """
    selectors: list[str] = []
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg in ("-b", "--bench"):
            if i + 1 < len(argv):
                selectors.append(argv[i + 1])
                i += 2
                continue
        elif arg.startswith("--bench="):
            selectors.append(arg[len("--bench="):])
        i += 1
    return selectors


def strip_trailing_cr(s: str) -> str:
    """Strip trailing CR characters. Defensive against Windows CRLF."""
    return s.rstrip("\r")


# ---------------------------------------------------------------------------
# ASV selector matching (exact replication of ASV's behavior)
# ---------------------------------------------------------------------------

def make_case_labels(bench_name: str, params_axes: list[list[str]]) -> list[tuple[str, tuple]]:
    """Expand parameter axes into (case_label, params_tuple) pairs.

    ASV constructs case labels as:
        benchmark.name(param1, param2, ...)

    The params are the cartesian product of the axes (last axis varies
    fastest), matching itertools.product order.
    """
    if not params_axes or not any(params_axes):
        # Non-parameterized benchmark: label is just the name
        return [(bench_name, ())]

    combinations = list(product(*params_axes))
    return [(bench_name, tuple(str(x) for x in combo)) for combo in combinations]


def format_asv_label(benchmark: str, params: tuple) -> str:
    """Format a case label exactly as ASV does for matching.

    ASV's unroll_result (asv/commands/compare.py:56) uses:
        f"{benchmark_name}({', '.join(params)})"
    — raw param values joined by ", ", NO repr().

    So params stored as ["2", "'count'"] produce: bench(2, 'count')
    """
    if not params:
        return benchmark
    return f"{benchmark}({', '.join(params)})"


def match_selector(selector: str, all_cases: list[tuple[str, str, tuple]]) -> list[tuple[str, tuple]]:
    """Match a single selector against all cases using ASV's rules.

    ASV applies re.search(selector, case_label) for each case.
    Invalid regex causes ASV to error — we replicate that by raising.

    all_cases: list of (case_label, benchmark_name, params_tuple)
    Returns: list of (benchmark_name, params_tuple) that matched.
    """
    # ASV uses re.search directly. Invalid regex is an error, NOT a
    # literal fallback.
    try:
        pattern = re.compile(selector)
    except re.error as exc:
        raise ValueError(f"invalid regex selector {selector!r}: {exc}")

    matched: list[tuple[str, tuple]] = []
    for case_label, bench_name, params in all_cases:
        if pattern.search(case_label):
            matched.append((bench_name, params))
    return matched


# ---------------------------------------------------------------------------
# Main logic
# ---------------------------------------------------------------------------

def load_benchmarks(benchmarks_file: Path) -> dict[str, dict[str, Any]]:
    """Load benchmarks.json. Returns {benchmark_name: metadata_dict}.

    benchmarks.json may contain top-level non-benchmark keys like 'version'
    (an integer format version). Filter those out.
    """
    try:
        raw = json.loads(benchmarks_file.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"error: cannot load benchmarks.json: {exc}", file=sys.stderr)
        sys.exit(2)

    if not isinstance(raw, dict):
        print(f"error: benchmarks.json is not a dict (got {type(raw).__name__})", file=sys.stderr)
        sys.exit(2)

    return {k: v for k, v in raw.items() if isinstance(v, dict)}


def build_all_cases(benchmarks: dict[str, dict[str, Any]]) -> list[tuple[str, str, tuple]]:
    """Build the full list of (case_label, benchmark_name, params_tuple) for all benchmarks.

    Uses ASV's parameter expansion: product(*params) with repr() formatting.
    """
    all_cases: list[tuple[str, str, tuple]] = []
    for name in sorted(benchmarks.keys()):
        meta = benchmarks[name]
        params = meta.get("params", [])
        if not isinstance(params, list):
            params = []
        # Ensure all axes are lists of strings
        str_axes = []
        for axis in params:
            if isinstance(axis, list):
                str_axes.append([str(x) for x in axis])
            else:
                str_axes.append([str(axis)])

        for _bench, params_tuple in make_case_labels(name, str_axes):
            label = format_asv_label(name, params_tuple)
            all_cases.append((label, name, params_tuple))
    return all_cases


def validate_and_write(
    benchmarks: dict[str, dict[str, Any]],
    selectors: list[str],
    output_file: Path,
) -> int:
    """Validate each selector and write expected-cases.jsonl.

    Returns 0 on success, 1 if any selector has zero matches or invalid regex.
    """
    all_cases = build_all_cases(benchmarks)

    if not selectors:
        # No -b given: all benchmarks are expected
        print(f"info: no -b selectors given, all {len(all_cases)} cases expected")
        expected: list[tuple[str, tuple]] = [
            (bench, params) for _, bench, params in all_cases
        ]
    else:
        expected = []
        all_passed = True

        for raw_sel in selectors:
            # Strip trailing CR before matching (P1.4: CR normalization
            # must happen before validation, not just in launcher)
            sel = strip_trailing_cr(raw_sel)
            if sel != raw_sel:
                print(f"info: stripped trailing CR from selector {raw_sel!r} → {sel!r}")

            try:
                matches = match_selector(sel, all_cases)
            except ValueError as exc:
                print(f"FAIL: {exc}", file=sys.stderr)
                all_passed = False
                continue

            if not matches:
                print(f"FAIL: selector {sel!r} matched ZERO cases", file=sys.stderr)
                # Suggest similar benchmarks
                for label, bench, params in all_cases:
                    sel_parts = re.split(r"[._()]", sel)
                    if any(part and part in label for part in sel_parts):
                        print(f"    (similar: {label})", file=sys.stderr)
                all_passed = False
            else:
                print(f"OK: selector {sel!r} matched {len(matches)} case(s):")
                for bench, params in matches[:5]:
                    print(f"  {format_case_label(bench, params)}")
                if len(matches) > 5:
                    print(f"  ... and {len(matches) - 5} more")
                expected.extend(matches)

        if not all_passed:
            print(f"\nerror: one or more selectors matched zero cases. "
                  f"Aborting before ASV launch to prevent stale-data false positives.",
                  file=sys.stderr)
            return 1

    # Deduplicate expected cases
    seen = set()
    unique_cases: list[tuple[str, tuple]] = []
    for name, params in expected:
        key = (name, params)
        if key not in seen:
            seen.add(key)
            unique_cases.append(key)

    write_expected_cases(output_file, unique_cases)
    print(f"\nWrote {len(unique_cases)} expected cases to {output_file}")
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Pre-check ASV benchmark selectors before launch.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        allow_abbrev=False,
    )
    p.add_argument("--benchmarks-file", required=True, type=Path,
                   help="Path to ASV's benchmarks.json (in the results directory).")
    p.add_argument("--output-file", required=True, type=Path,
                   help="Path to write expected-cases.jsonl. Should be OUTSIDE the "
                        "run directory (sibling file) to avoid conflict with "
                        "asv-background.sh's empty-directory requirement.")
    p.add_argument("asv_args", nargs="*",
                   help="ASV command args to parse for -b/--bench selectors.")
    args, asv_args = p.parse_known_args(argv)
    args.asv_args = asv_args
    return args


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    if not args.benchmarks_file.is_file():
        print(f"error: benchmarks file not found: {args.benchmarks_file}", file=sys.stderr)
        return 2

    benchmarks = load_benchmarks(args.benchmarks_file)
    selectors = extract_selectors(args.asv_args)

    return validate_and_write(benchmarks, selectors, args.output_file)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
