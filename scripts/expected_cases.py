#!/usr/bin/env python3
"""
expected_cases.py — Shared read/write functions for expected-cases JSONL.

Used by both validate-asv-selection.py (writer) and compare-asv.py (reader)
to ensure format consistency.

JSONL format (one JSON object per line):
    {"benchmark":"suite.time_x","params":["2","count"]}
    {"benchmark":"suite.time_y","params":[]}

Params is a list of strings (may contain commas, spaces, parentheses).
"""
from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


def write_expected_cases(path: Path, cases: list[tuple[str, tuple]]) -> None:
    """Write expected cases as JSONL. Each line is a JSON object."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for bench, params in sorted(cases):
            entry = {"benchmark": bench, "params": list(params)}
            f.write(json.dumps(entry) + "\n")


def read_expected_cases(path: Path) -> set[tuple[str, tuple]] | None:
    """Read expected cases from JSONL.

    Returns a set of (benchmark, params_tuple) pairs.

    Returns None (and prints error to stderr) if:
      - file doesn't exist
      - file is empty
      - file contains invalid JSON
      - file has wrong structure

    This is fail-closed: the caller must treat None as exit 2.
    """
    if not path.is_file():
        print(f"error: expected-cases file not found: {path}", file=sys.stderr)
        return None

    try:
        content = path.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"error: cannot read expected-cases file: {exc}", file=sys.stderr)
        return None

    lines = [line.strip() for line in content.splitlines() if line.strip()]
    if not lines:
        print(f"error: expected-cases file is empty: {path}", file=sys.stderr)
        return None

    cases: set[tuple[str, tuple]] = set()
    for i, line in enumerate(lines, 1):
        try:
            obj = json.loads(line)
        except json.JSONDecodeError as exc:
            print(f"error: invalid JSON on line {i} of {path}: {exc}", file=sys.stderr)
            return None

        if not isinstance(obj, dict) or "benchmark" not in obj or "params" not in obj:
            print(f"error: line {i} of {path} missing 'benchmark' or 'params' key", file=sys.stderr)
            return None

        bench = str(obj["benchmark"])
        params_raw = obj["params"]
        if not isinstance(params_raw, list):
            print(f"error: line {i} of {path} 'params' is not a list", file=sys.stderr)
            return None

        params = tuple(str(p) for p in params_raw)
        cases.add((bench, params))

    return cases


def format_case_label(benchmark: str, params: tuple) -> str:
    """Format a case as a human-readable label for display."""
    if params:
        return f"{benchmark}({', '.join(str(p) for p in params)})"
    return benchmark
