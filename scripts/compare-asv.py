#!/usr/bin/env python3
"""
compare-asv.py — Compare two ASV 0.6.x result sets, per parameter case.

Parses the JSON files ASV writes under its results directory (configured by
`results_dir` in asv.conf.json, often `results/` relative to asv_bench).
Picks a baseline and a candidate run, and prints a per-parameter-case
comparison. The main agent reads this table instead of the raw ASV log.

ASV 0.6.x result file structure (verified against real files):

    top-level keys: commit_hash, env_name, date, params, python, requirements,
                    env_vars, result_columns, results, durations, version

    result_columns: ['result', 'params', 'version', 'started_at', 'duration',
                     'stats_ci_99_a', 'stats_ci_99_b', 'stats_q_25',
                     'stats_q_75', 'stats_number', 'stats_repeat', 'samples',
                     'profile']

    results: { benchmark_name: [ [vals_for_col0], [vals_for_col1], ... ] }
             Each benchmark has one entry per parameter combination.
             Each column is a list aligned with the parameter combinations.
             The 'result' column holds the measurement samples (list of
             floats); the 'params' column holds the parameter tuples.

Usage:
    compare-asv.py --results-dir <DIR>
                   --baseline <commit-hash>
                   --candidate <commit-hash>
                   [--machine <name>]
                   [--environment <env-name>]
                   [--threshold <percent>]
                   [--policy no-regression|require-improvement]
                   [--min-gain <percent>]

Required:
    --results-dir DIR    Directory containing ASV result JSON files.
    --baseline HASH      Commit hash (or unique prefix) for the baseline run.
    --candidate HASH     Commit hash (or unique prefix) for the candidate run.

Optional:
    --machine NAME       Restrict to results from this machine. If omitted and
                         multiple machines are found, the script errors.
    --environment NAME   Restrict to results from this env_name. If omitted and
                         multiple envs are found, the script errors.
    --threshold PCT      Regression threshold in percent (default 5). A case
                         counts as regressed if candidate is more than PCT%
                         slower than baseline.
    --policy             Comparison policy (default: no-regression).
                         no-regression:       exit 1 if any case regressed.
                         require-improvement: exit 1 if any case failed to
                                              improve by at least --min-gain.
    --min-gain PCT       Minimum improvement required under
                         require-improvement policy (default 5).

Output (stdout):
    A markdown table with one row per parameter case:
        benchmark(params) | baseline | candidate | ratio | status
    Followed by a SUMMARY line.

Exit status:
    0  All cases pass the policy.
    1  At least one case fails the policy.
    2  Could not compare (no results, missing commit, ambiguous machine/env).
"""
from __future__ import annotations

import argparse
import json
import math
import statistics
import sys
from dataclasses import dataclass, field
from itertools import product
from pathlib import Path
from typing import Any


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------

@dataclass
class AsvRun:
    """One ASV result file loaded into memory."""

    path: Path
    commit_hash: str
    env_name: str
    machine_name: str  # from the parent directory name
    date: float  # top-level 'date' field (ms epoch), for recency
    result_columns: list[str]
    results: dict[str, list[list]]  # benchmark_name -> list of column-lists
    params: dict[str, Any]  # machine/env params from top level

    @property
    def short_hash(self) -> str:
        return self.commit_hash[:12] if self.commit_hash else "<unknown>"


@dataclass
class CaseRow:
    """One row of the comparison table — a single parameter combination."""

    benchmark: str
    params: tuple  # parameter tuple for this case, e.g. (2, 'count')
    baseline_value: float | None  # median of baseline samples, None if failed
    candidate_value: float | None
    ratio: float | None  # candidate / baseline, None if not comparable
    status: str  # PASS / REGRESSION / IMPROVED / BORDERLINE / NO_CHANGE / NOT_COMPARABLE / FAILED


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

# Files to skip when looking for result JSONs
_SKIP_FILES = {"machine.json", "benchmarks.json"}


def load_run(path: Path, machine_name: str) -> AsvRun | None:
    """Load a single ASV 0.6.x result JSON file.

    Returns None if the file isn't a valid result file (so the caller skips
    silently). This correctly skips machine.json, benchmarks.json, and any
    non-ASV JSON that happens to be in the directory.
    """
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"warn: skipping {path}: {exc}", file=sys.stderr)
        return None

    if not isinstance(raw, dict):
        return None

    # ASV 0.6.x result files have 'result_columns' and 'results'. This is the
    # reliable discriminator — machine.json/benchmarks.json don't have these.
    if "result_columns" not in raw or "results" not in raw:
        return None

    cols = raw["result_columns"]
    if not isinstance(cols, list) or not isinstance(raw["results"], dict):
        return None

    return AsvRun(
        path=path,
        commit_hash=str(raw.get("commit_hash", "")),
        env_name=str(raw.get("env_name", "")),
        machine_name=machine_name,
        date=float(raw.get("date", 0.0) or 0.0),
        result_columns=cols,
        results=raw["results"],
        params=raw.get("params", {}) if isinstance(raw.get("params"), dict) else {},
    )


def discover_runs(results_dir: Path) -> list[AsvRun]:
    """Find and load every ASV 0.6.x result file under results_dir.

    ASV lays out files as `<machine>/<commit>-<env>.json`. The machine name
    comes from the parent directory. We glob recursively to be lenient.
    """
    if not results_dir.is_dir():
        return []

    runs: list[AsvRun] = []
    for path in sorted(results_dir.rglob("*.json")):
        if path.name in _SKIP_FILES:
            continue
        # Machine name is the parent directory (ASV convention).
        machine_name = path.parent.name
        run = load_run(path, machine_name)
        if run is not None:
            runs.append(run)
    return runs


# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------

def select_run(
    runs: list[AsvRun],
    selector: str,
    machine: str | None,
    environment: str | None,
) -> AsvRun | None:
    """Pick one run by commit-hash prefix, filtered by machine/env.

    If machine/environment is specified, only consider runs matching them.
    If not specified but multiple distinct values exist, return None (caller
    should error and ask the caller to disambiguate).
    """
    candidates = runs

    # Filter by machine if specified.
    if machine:
        candidates = [r for r in candidates if r.machine_name == machine]
    elif len({r.machine_name for r in candidates}) > 1:
        print(
            f"error: multiple machines found: {sorted({r.machine_name for r in candidates})}. "
            f"Specify --machine to disambiguate.",
            file=sys.stderr,
        )
        return None

    # Filter by environment if specified.
    if environment:
        candidates = [r for r in candidates if r.env_name == environment]
    elif len({r.env_name for r in candidates}) > 1:
        print(
            f"error: multiple environments found. Specify --environment to disambiguate.",
            file=sys.stderr,
        )
        return None

    # Match by commit hash prefix (case-insensitive).
    sel = selector.lower()
    matches = [r for r in candidates if r.commit_hash.lower().startswith(sel)]
    if not matches:
        return None
    if len(matches) > 1:
        print(
            f"error: commit prefix '{selector}' matched {len(matches)} runs: "
            f"{[r.short_hash for r in matches]}. Use a longer prefix.",
            file=sys.stderr,
        )
        return None
    return matches[0]


# ---------------------------------------------------------------------------
# Per-case extraction
# ---------------------------------------------------------------------------

def _column_index(run: AsvRun, col_name: str) -> int | None:
    """Get the index of a column in result_columns, or None if absent."""
    try:
        return run.result_columns.index(col_name)
    except ValueError:
        return None


def extract_cases(run: AsvRun) -> list[tuple[str, tuple, float | None]]:
    """Extract all parameter cases from a run.

    Returns a list of (benchmark_name, params_tuple, median_value).
    median_value is None if the benchmark failed (null/empty result).
    Each parameter combination produces one entry — they are NOT merged.

    ASV 0.6.x parameter layout (verified against real result files):
    - The 'params' column holds the parameter AXES, not combinations.
      e.g. params = [['2','4','8'], ['count','last',...]]  (2 axes)
    - The 'result' column holds one entry per parameter COMBINATION,
      in itertools.product(*params) order (last axis varies fastest).
      e.g. result = [val(2,count), val(2,last), ..., val(8,var)]  (24 entries)
    - So we must expand params via product() to get the correct pairing.
    """
    result_idx = _column_index(run, "result")
    params_idx = _column_index(run, "params")
    if result_idx is None:
        return []

    cases: list[tuple[str, tuple, float | None]] = []
    for bench_name, columns in run.results.items():
        if not isinstance(columns, list) or result_idx >= len(columns):
            continue

        result_col = columns[result_idx]
        param_col = columns[params_idx] if params_idx is not None and params_idx < len(columns) else None

        # Determine parameter combinations via product(*param_axes).
        # param_col is a list of axes: [[axis0_values], [axis1_values], ...]
        # product(*param_col) gives the cartesian product in the correct order.
        if param_col and isinstance(param_col, list) and all(isinstance(a, list) for a in param_col):
            param_combinations = list(product(*param_col))
            param_tuples = [tuple(str(x) for x in combo) for combo in param_combinations]
        elif param_col and isinstance(param_col, list) and param_col:
            # Single-axis parameter (flat list of values).
            param_tuples = [tuple([str(x)]) for x in param_col]
        else:
            # Non-parameterized benchmark.
            param_tuples = [()]

        # result_col should have one entry per param combination.
        # Each entry is either a scalar (the median already computed by ASV)
        # or a list of measurement samples, or null (failed).
        if result_col is None:
            values = [None] * len(param_tuples)
        elif isinstance(result_col, list):
            values = result_col
        else:
            # Single scalar result, non-parameterized.
            values = [result_col]

        # Guard: mismatched counts indicate a parse error or corrupted file.
        if len(values) != len(param_tuples):
            print(
                f"warn: {bench_name}: result count ({len(values)}) != "
                f"param combination count ({len(param_tuples)}), skipping",
                file=sys.stderr,
            )
            continue

        for params_tuple, value in zip(param_tuples, values):
            median = _median_of_value(value)
            cases.append((bench_name, params_tuple, median))

    return cases


def _normalize_params(raw: Any) -> tuple:
    """Normalize ASV params representation to a hashable tuple."""
    if raw is None:
        return ()
    if isinstance(raw, (list, tuple)):
        return tuple(str(p) if not isinstance(p, str) else p for p in raw)
    if isinstance(raw, dict):
        # Some ASV versions use dict params; sort keys for stability.
        return tuple(sorted((str(k), str(v)) for k, v in raw.items()))
    return (str(raw),)


def _median_of_value(value: Any) -> float | None:
    """Reduce a result value (scalar or sample list) to a median, or None."""
    if value is None:
        return None
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, list):
        nums = [float(x) for x in value if isinstance(x, (int, float)) and not isinstance(x, bool)]
        if not nums:
            return None
        return statistics.median(nums)
    return None


# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------

def format_value(value: float | None) -> str:
    if value is None:
        return "n/a"
    if value < 1e-6:
        return f"{value * 1e9:.2f} ns"
    if value < 1e-3:
        return f"{value * 1e6:.2f} µs"
    if value < 1.0:
        return f"{value * 1e3:.2f} ms"
    if value < 60.0:
        return f"{value:.3f} s"
    return f"{value / 60.0:.2f} min"


def format_params(params: tuple) -> str:
    if not params:
        return ""
    return "(" + ", ".join(str(p) for p in params) + ")"


def format_ratio(ratio: float | None) -> str:
    if ratio is None:
        return "n/a"
    return f"{ratio:.2f}"


# ---------------------------------------------------------------------------
# Comparison
# ---------------------------------------------------------------------------

def classify_case(
    baseline: float | None,
    candidate: float | None,
    threshold_pct: float,
    policy: str,
    min_gain_pct: float,
) -> tuple[str, float | None]:
    """Classify one parameter case. Returns (status, ratio).

    ratio = candidate / baseline. <1 means faster, >1 means slower.
    """
    if baseline is None and candidate is None:
        return "FAILED", None
    if baseline is None or candidate is None:
        # One side failed — can't compare.
        return "NOT_COMPARABLE", None
    if baseline <= 0:
        return "NOT_COMPARABLE", None

    # Guard against NaN / Inf. Without this, NaN > threshold is False and
    # NaN < -threshold is also False, so NaN would silently fall through to
    # PASS — a false positive. math.isfinite rejects both NaN and Inf.
    if not math.isfinite(baseline) or not math.isfinite(candidate):
        return "NOT_COMPARABLE", None

    ratio = candidate / baseline
    change_pct = (candidate - baseline) / baseline * 100.0

    if policy == "require-improvement":
        # Every case must improve by at least min_gain_pct.
        if change_pct <= -min_gain_pct:
            return "PASS", ratio
        elif change_pct < 0:
            return "BORDERLINE", ratio  # improved but not enough
        elif change_pct <= threshold_pct:
            return "NO_CHANGE", ratio  # within noise, no improvement
        else:
            return "REGRESSION", ratio
    else:  # no-regression
        if change_pct > threshold_pct:
            return "REGRESSION", ratio
        elif change_pct < -threshold_pct:
            return "IMPROVED", ratio
        else:
            return "PASS", ratio


def compare_runs(
    baseline: AsvRun,
    candidate: AsvRun,
    threshold_pct: float,
    policy: str,
    min_gain_pct: float,
) -> tuple[list[CaseRow], list[str], list[str]]:
    """Compare two runs case by case. Returns (rows, only_baseline, only_candidate)."""
    b_cases = extract_cases(baseline)
    c_cases = extract_cases(candidate)

    b_map: dict[tuple, float | None] = {(name, params): val for name, params, val in b_cases}
    c_map: dict[tuple, float | None] = {(name, params): val for name, params, val in c_cases}

    b_keys = set(b_map)
    c_keys = set(c_map)
    common = sorted(b_keys & c_keys)
    only_baseline = sorted(f"{name}{format_params(params)}" for name, params in b_keys - c_keys)
    only_candidate = sorted(f"{name}{format_params(params)}" for name, params in c_keys - b_keys)

    rows: list[CaseRow] = []
    for name, params in common:
        b_val = b_map[(name, params)]
        c_val = c_map[(name, params)]
        status, ratio = classify_case(b_val, c_val, threshold_pct, policy, min_gain_pct)
        rows.append(CaseRow(
            benchmark=name,
            params=params,
            baseline_value=b_val,
            candidate_value=c_val,
            ratio=ratio,
            status=status,
        ))

    return rows, only_baseline, only_candidate


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

def print_table(
    rows: list[CaseRow],
    baseline: AsvRun,
    candidate: AsvRun,
    only_baseline: list[str],
    only_candidate: list[str],
    threshold_pct: float,
    policy: str,
    min_gain_pct: float,
) -> bool:
    """Print the markdown table. Returns True if any case failed the policy."""
    print(f"Baseline: `{baseline.short_hash}`  Candidate: `{candidate.short_hash}`")
    print(f"Machine: {baseline.machine_name}  Environment: {baseline.env_name}")
    print(f"Policy: {policy}  Threshold: {threshold_pct:.0f}%", end="")
    if policy == "require-improvement":
        print(f"  Min gain: {min_gain_pct:.0f}%")
    else:
        print()
    print()

    if not rows:
        print("(no common benchmark cases to compare)")
        if only_baseline or only_candidate:
            print(f"  only in baseline: {len(only_baseline)}, only in candidate: {len(only_candidate)}")
        print()
        print("SUMMARY: no common cases — comparison impossible")
        return True  # no common cases = failure

    print("| benchmark | baseline | candidate | ratio | status |")
    print("|-----------|----------|-----------|-------|--------|")

    any_fail = False
    for row in rows:
        label = row.benchmark + format_params(row.params)
        status_icon = {
            "PASS": "✅",
            "IMPROVED": "✅",
            "REGRESSION": "❌",
            "BORDERLINE": "⚠️",
            "NO_CHANGE": "➖",
            "NOT_COMPARABLE": "❓",
            "FAILED": "💀",
        }.get(row.status, "")
        print(
            f"| {label} | {format_value(row.baseline_value)} | "
            f"{format_value(row.candidate_value)} | {format_ratio(row.ratio)} | "
            f"{row.status} {status_icon} |"
        )
        # Determine failure based on policy.
        if policy == "require-improvement":
            if row.status in ("REGRESSION", "NO_CHANGE", "BORDERLINE", "NOT_COMPARABLE", "FAILED"):
                any_fail = True
        else:  # no-regression
            if row.status in ("REGRESSION", "NOT_COMPARABLE", "FAILED"):
                any_fail = True

    if only_baseline:
        print()
        print(f"Cases only in baseline ({len(only_baseline)}):")
        for name in only_baseline:
            print(f"  - {name}")
    if only_candidate:
        print()
        print(f"Cases only in candidate ({len(only_candidate)}):")
        for name in only_candidate:
            print(f"  - {name}")

    # Missing cases count as failure under both policies. If candidate is
    # missing cases that baseline had (or vice versa), the comparison is
    # incomplete and must not silently pass.
    if only_baseline or only_candidate:
        any_fail = True

    # Summary — grep-friendly.
    status_counts: dict[str, int] = {}
    for r in rows:
        status_counts[r.status] = status_counts.get(r.status, 0) + 1
    if only_baseline:
        status_counts["only_baseline"] = len(only_baseline)
    if only_candidate:
        status_counts["only_candidate"] = len(only_candidate)
    parts = [f"{count} {status.lower()}" for status, count in sorted(status_counts.items())]
    print()
    print(f"SUMMARY: {', '.join(parts)}")
    return any_fail


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Compare two ASV 0.6.x result sets, per parameter case.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--results-dir", required=True, type=Path,
                   help="Directory containing ASV result JSON files.")
    p.add_argument("--baseline", required=True,
                   help="Commit hash (or prefix) for the baseline run.")
    p.add_argument("--candidate", required=True,
                   help="Commit hash (or prefix) for the candidate run.")
    p.add_argument("--machine", default=None,
                   help="Restrict to results from this machine.")
    p.add_argument("--environment", default=None,
                   help="Restrict to results from this env_name.")
    p.add_argument("--threshold", type=float, default=5.0,
                   help="Regression threshold in percent. Default 5.")
    p.add_argument("--policy", choices=["no-regression", "require-improvement"],
                   default="no-regression",
                   help="Comparison policy. Default: no-regression.")
    p.add_argument("--min-gain", type=float, default=5.0,
                   help="Min improvement %% required under require-improvement. Default 5.")
    return p.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    if not args.results_dir.is_dir():
        print(f"error: results directory not found: {args.results_dir}", file=sys.stderr)
        return 2

    runs = discover_runs(args.results_dir)
    if not runs:
        print(f"error: no ASV result files found under {args.results_dir}", file=sys.stderr)
        print("  (ASV 0.6.x stores results in the directory named by 'results_dir'", file=sys.stderr)
        print("   in asv.conf.json — often 'results/' relative to asv_bench, not '.asv/results/')", file=sys.stderr)
        return 2

    baseline = select_run(runs, args.baseline, args.machine, args.environment)
    candidate = select_run(runs, args.candidate, args.machine, args.environment)

    if baseline is None:
        print(f"error: could not find baseline run matching '{args.baseline}'.", file=sys.stderr)
        available = sorted({r.short_hash for r in runs})
        print(f"  available commits: {available[:10]}", file=sys.stderr)
        return 2
    if candidate is None:
        print(f"error: could not find candidate run matching '{args.candidate}'.", file=sys.stderr)
        available = sorted({r.short_hash for r in runs})
        print(f"  available commits: {available[:10]}", file=sys.stderr)
        return 2
    if baseline.path == candidate.path:
        print(f"error: baseline and candidate resolved to the same file ({baseline.path}).", file=sys.stderr)
        return 2

    rows, only_baseline, only_candidate = compare_runs(
        baseline, candidate, args.threshold, args.policy, args.min_gain
    )

    # P0.3: zero common cases = cannot compare, exit 2 (not exit 0).
    if not rows:
        print_table(
            rows, baseline, candidate, only_baseline, only_candidate,
            args.threshold, args.policy, args.min_gain
        )
        return 2

    any_fail = print_table(
        rows, baseline, candidate, only_baseline, only_candidate,
        args.threshold, args.policy, args.min_gain
    )
    return 1 if any_fail else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
