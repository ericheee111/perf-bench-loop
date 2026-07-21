#!/usr/bin/env python3
"""
compare-asv.py — Compare two ASV result sets and emit a markdown table.

Parses the JSON files that ASV writes under `.asv/results/`, picks a baseline
and a candidate run, and prints a per-benchmark comparison. The main agent
reads this table instead of the raw ASV log.

Usage:
    compare-asv.py --results-dir <DIR>
                   [--baseline <commit-hash-or-keyword>]
                   [--candidate <commit-hash-or-keyword>]
                   [--threshold <percent>]
                   [--help]

Arguments:
    --results-dir DIR    Directory containing ASV result JSON files. This is
                         typically the `.asv/results/` folder. Required.
    --baseline HASH      Commit hash (or unique prefix, or the keyword
                         `HEAD^`) identifying the baseline run. If omitted,
                         the script picks the second-most-recent run.
    --candidate HASH     Commit hash (or prefix, or `HEAD`) identifying the
                         candidate run. If omitted, the script picks the most
                         recent run.
    --threshold PCT      Regression threshold in percent. A benchmark counts
                         as regressed if the candidate is more than PCT%
                         slower than the baseline. Default 5.

Output (stdout):
    A markdown table with columns:
        benchmark | baseline | candidate | change | significant
    Followed by a one-line summary.

Exit status:
    0  Comparison completed, no regression detected.
    1  Comparison completed, at least one benchmark regressed.
    2  Could not compare (no results, missing baseline/candidate, parse error).

The exit code lets the main agent branch without parsing the table.
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------

@dataclass
class AsvRun:
    """One ASV result file loaded into memory."""

    path: Path
    commit_hash: str
    started_at: float
    results: dict[str, Any]  # benchmark name -> value (scalar / list / param dict / None)
    env_name: str = ""

    @property
    def short_hash(self) -> str:
        return self.commit_hash[:12] if self.commit_hash else "<unknown>"


@dataclass
class BenchmarkRow:
    """One row of the comparison table."""

    name: str
    baseline_value: float | None  # None if failed/missing on baseline
    candidate_value: float | None
    change_pct: float | None       # None if not comparable
    significant: bool              # True if regression exceeds threshold


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

def load_run(path: Path) -> AsvRun | None:
    """Load a single ASV result JSON file. Return None if it can't be parsed
    as an ASV result (so the caller can skip silently)."""
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"warn: skipping {path}: {exc}", file=sys.stderr)
        return None

    # ASV result files have a `result` dict and a `commit_hash`. Some files
    # under .asv/results/ (e.g. machine.json) don't — skip those.
    if not isinstance(raw, dict) or "result" not in raw:
        return None

    return AsvRun(
        path=path,
        commit_hash=str(raw.get("commit_hash", "")),
        started_at=float(raw.get("started_at", 0.0) or 0.0),
        results=raw["result"] if isinstance(raw["result"], dict) else {},
        env_name=str(raw.get("env_name", "")),
    )


def discover_runs(results_dir: Path) -> list[AsvRun]:
    """Find and load every ASV result file under results_dir.

    ASV lays out files as `<machine>/<commit>-<env>.json` under .asv/results/.
    We glob recursively to be lenient about layout.
    """
    if not results_dir.is_dir():
        return []

    runs: list[AsvRun] = []
    for path in sorted(results_dir.rglob("*.json")):
        run = load_run(path)
        if run is not None:
            runs.append(run)
    return runs


# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------

def select_run(
    runs: list[AsvRun], selector: str | None, fallback_rank: int
) -> AsvRun | None:
    """Pick one run by commit-hash prefix, or by recency rank if selector
    is None. fallback_rank=0 means most recent, 1 means second-most-recent."""
    if not runs:
        return None

    if selector is None:
        # Sort by started_at descending, then by path for stable ordering.
        ordered = sorted(runs, key=lambda r: (-r.started_at, str(r.path)))
        if fallback_rank < len(ordered):
            return ordered[fallback_rank]
        return None

    # Selector given: match by commit hash prefix (case-insensitive). Also
    # accept the symbolic keywords HEAD / HEAD^ for ergonomics.
    sel = selector.lower()
    if sel == "head":
        ordered = sorted(runs, key=lambda r: (-r.started_at, str(r.path)))
        return ordered[0] if ordered else None
    if sel in ("head^", "head~1"):
        ordered = sorted(runs, key=lambda r: (-r.started_at, str(r.path)))
        return ordered[1] if len(ordered) > 1 else None

    matches = [r for r in runs if r.commit_hash.lower().startswith(sel)]
    if not matches:
        return None
    # If multiple commits match the prefix, prefer the most recent.
    matches.sort(key=lambda r: (-r.started_at, str(r.path)))
    return matches[0]


# ---------------------------------------------------------------------------
# Value extraction
# ---------------------------------------------------------------------------

def median_of(value: Any) -> float | None:
    """Reduce any ASV result value to a single median number, or None if the
    benchmark failed or produced no usable numbers.

    Handles:
      - scalar numbers
      - lists of numbers (repeated measurements)
      - None (failed benchmark)
      - parameterized dicts: returns the median across all parameter values,
        since the table is one row per benchmark. Callers who need per-param
        breakdown should use `asv compare` directly.
    """
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
    if isinstance(value, dict) and "result" in value:
        # Parameterized benchmark: flatten all results into one list.
        inner = value["result"]
        flat: list[float] = []
        if isinstance(inner, list):
            for item in inner:
                m = median_of(item)
                if m is not None:
                    flat.append(m)
        elif isinstance(inner, (int, float)):
            flat.append(float(inner))
        if not flat:
            return None
        return statistics.median(flat)
    return None


def format_value(value: float | None) -> str:
    """Human-friendly formatting. Returns 'n/a' for missing values."""
    if value is None:
        return "n/a"
    # ASV defaults to seconds; pick a sensible unit.
    if value < 1e-6:
        return f"{value * 1e9:.2f} ns"
    if value < 1e-3:
        return f"{value * 1e6:.2f} µs"
    if value < 1.0:
        return f"{value * 1e3:.2f} ms"
    if value < 60.0:
        return f"{value:.3f} s"
    return f"{value / 60.0:.2f} min"


# ---------------------------------------------------------------------------
# Comparison
# ---------------------------------------------------------------------------

def compare(
    baseline: AsvRun, candidate: AsvRun, threshold_pct: float
) -> tuple[list[BenchmarkRow], list[str], list[str]]:
    """Compare two runs. Returns (rows, only_in_baseline, only_in_candidate)."""
    rows: list[BenchmarkRow] = []
    only_baseline = sorted(set(baseline.results) - set(candidate.results))
    only_candidate = sorted(set(candidate.results) - set(baseline.results))

    for name in sorted(set(baseline.results) & set(candidate.results)):
        b = median_of(baseline.results[name])
        c = median_of(candidate.results[name])

        change_pct: float | None = None
        significant = False
        if b is not None and c is not None and b > 0:
            change_pct = (c - b) / b * 100.0
            # Significant only flags regressions (candidate slower). Improvements
            # are noted in the change column but don't trip the exit code.
            significant = change_pct > threshold_pct

        rows.append(BenchmarkRow(
            name=name,
            baseline_value=b,
            candidate_value=c,
            change_pct=change_pct,
            significant=significant,
        ))

    return rows, only_baseline, only_candidate


def format_change(change_pct: float | None) -> str:
    if change_pct is None:
        return "n/a"
    sign = "+" if change_pct >= 0 else ""
    return f"{sign}{change_pct:.1f}%"


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

def print_table(
    rows: list[BenchmarkRow],
    baseline: AsvRun,
    candidate: AsvRun,
    only_baseline: list[str],
    only_candidate: list[str],
    threshold_pct: float,
) -> bool:
    """Print the markdown table. Returns True if any regression was detected."""
    print(f"Baseline: `{baseline.short_hash}`  Candidate: `{candidate.short_hash}`")
    print(f"Regression threshold: {threshold_pct:.0f}%")
    print()
    print("| benchmark | baseline | candidate | change | significant |")
    print("|-----------|----------|-----------|--------|-------------|")

    any_regression = False
    for row in rows:
        if row.significant:
            any_regression = True
        sig = "yes ⚠️" if row.significant else ("improved ✅" if (row.change_pct is not None and row.change_pct < 0) else "no")
        print(
            f"| {row.name} | {format_value(row.baseline_value)} | "
            f"{format_value(row.candidate_value)} | {format_change(row.change_pct)} | {sig} |"
        )

    if only_baseline:
        print()
        print(f"Benchmarks only in baseline ({len(only_baseline)}):")
        for name in only_baseline:
            print(f"  - {name}")
    if only_candidate:
        print()
        print(f"Benchmarks only in candidate ({len(only_candidate)}):")
        for name in only_candidate:
            print(f"  - {name}")

    # Summary line — easy for the main agent to grep.
    reg_count = sum(1 for r in rows if r.significant)
    improved_count = sum(1 for r in rows if r.change_pct is not None and r.change_pct < 0 and not r.significant)
    print()
    print(
        f"SUMMARY: {reg_count} regressed, {improved_count} improved, "
        f"{len(rows) - reg_count - improved_count} unchanged/noise"
    )
    return any_regression


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Compare two ASV result sets and emit a markdown table.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument(
        "--results-dir",
        required=True,
        type=Path,
        help="Directory containing ASV result JSON files (typically .asv/results/).",
    )
    p.add_argument(
        "--baseline",
        default=None,
        help="Commit hash (or prefix) for the baseline run. "
             "Keywords: HEAD^, HEAD~1. If omitted, uses second-most-recent run.",
    )
    p.add_argument(
        "--candidate",
        default=None,
        help="Commit hash (or prefix) for the candidate run. "
             "Keyword: HEAD. If omitted, uses most recent run.",
    )
    p.add_argument(
        "--threshold",
        type=float,
        default=5.0,
        help="Regression threshold in percent. Default 5.",
    )
    return p.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    if not args.results_dir.is_dir():
        print(f"error: results directory not found: {args.results_dir}", file=sys.stderr)
        return 2

    runs = discover_runs(args.results_dir)
    if not runs:
        print(f"error: no ASV result files found under {args.results_dir}", file=sys.stderr)
        return 2

    baseline = select_run(runs, args.baseline, fallback_rank=1)
    candidate = select_run(runs, args.candidate, fallback_rank=0)

    if baseline is None:
        print(
            "error: could not select a baseline run. "
            "Specify --baseline <commit-hash>.",
            file=sys.stderr,
        )
        return 2
    if candidate is None:
        print(
            "error: could not select a candidate run. "
            "Specify --candidate <commit-hash>.",
            file=sys.stderr,
        )
        return 2
    if baseline is candidate:
        print(
            "error: baseline and candidate resolved to the same run "
            f"({baseline.short_hash}). Specify --baseline and --candidate "
            f"with distinct commit hashes.",
            file=sys.stderr,
        )
        return 2

    rows, only_baseline, only_candidate = compare(baseline, candidate, args.threshold)
    any_regression = print_table(
        rows, baseline, candidate, only_baseline, only_candidate, args.threshold
    )

    return 1 if any_regression else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
