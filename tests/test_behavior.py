#!/usr/bin/env python3
"""
Self-contained behavioral tests for perf-bench-loop.

All fixtures are synthetic — no external files or network needed.
No test is ever SKIPped; every test asserts exit codes and output.

Run: python tests/test_behavior.py
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parent.parent
SCRIPTS = SKILL_DIR / "scripts"

passed = 0
failed = 0
errors = []


def run_python(script, *args, env=None):
    """Run a Python script, return (exit_code, stdout, stderr)."""
    cmd = [sys.executable, str(SCRIPTS / script)] + list(args)
    result = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=30)
    return result.returncode, result.stdout, result.stderr


def to_bash_path(p):
    """Convert a Windows path to a bash-compatible path for bash scripts."""
    s = str(p)
    # C:\Users\... → /c/Users/...
    if len(s) >= 2 and s[1] == ":" and s[0].isalpha():
        drive = s[0].lower()
        rest = s[2:].replace("\\", "/")
        return f"/{drive}{rest}"
    return s


def run_bash(script, *args, env=None, timeout=30):
    """Run a bash script, return (exit_code, stdout, stderr).
    Converts all path args to bash-compatible format."""
    bash_args = [to_bash_path(a) if "/" in a or "\\" in a else a for a in args]
    cmd = ["bash", str(SCRIPTS / script)] + bash_args
    result = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=timeout)
    return result.returncode, result.stdout, result.stderr


def assert_eq(actual, expected, name, detail=""):
    global passed, failed
    if actual == expected:
        passed += 1
        print(f"  PASS: {name}")
    else:
        failed += 1
        msg = f"  FAIL: {name} — expected {expected}, got {actual}"
        if detail:
            msg += f" | {detail}"
        print(msg)
        errors.append(msg)


def assert_contains(haystack, needle, name):
    global passed, failed
    if needle in haystack:
        passed += 1
        print(f"  PASS: {name}")
    else:
        failed += 1
        msg = f"  FAIL: {name} — '{needle}' not in output"
        print(msg)
        errors.append(msg)


def assert_not_contains(haystack, needle, name):
    global passed, failed
    if needle not in haystack:
        passed += 1
        print(f"  PASS: {name}")
    else:
        failed += 1
        msg = f"  FAIL: {name} — '{needle}' unexpectedly in output"
        print(msg)
        errors.append(msg)


# ---------------------------------------------------------------------------
# Synthetic fixture builders
# ---------------------------------------------------------------------------

def make_benchmarks_json(path, benchmarks):
    """Write a synthetic benchmarks.json.

    benchmarks: dict of {name: {"params": [[...], [...]], "version": "..."}}
    """
    data = {"version": 2}
    for name, meta in benchmarks.items():
        data[name] = {
            "params": meta.get("params", []),
            "param_names": meta.get("param_names", []),
            "version": meta.get("version", "v1"),
            "unit": meta.get("unit", "seconds"),
            "type": meta.get("type", "time"),
            "name": name,
            "code": "",
        }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data), encoding="utf-8")


def make_result_file(path, commit_hash, results, env_name="test-env", date=1000):
    """Write a synthetic ASV 0.6.x result JSON.

    results: {bench_name: [result_col, params_col, version, started_at, duration]}
    """
    data = {
        "commit_hash": commit_hash,
        "env_name": env_name,
        "date": date,
        "params": {},
        "python": "3.14",
        "requirements": {},
        "env_vars": {},
        "result_columns": ["result", "params", "version", "started_at", "duration"],
        "results": results,
        "durations": {},
        "version": 2,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data), encoding="utf-8")


def make_param_result(values, params_axes, version="v1"):
    """Create a results entry for a parameterized benchmark.

    values: list of result values (one per param combo)
    params_axes: list of axes, e.g. [['2','4'], ['count','sum']]
    """
    return [values, params_axes, version, 1000, 1.0]


def make_simple_result(value, version="v1"):
    """Create a results entry for a non-parameterized benchmark."""
    return [value, [], version, 1000, 1.0]


def write_jsonl(path, entries):
    """Write JSONL file. entries: list of (benchmark, params_list)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for bench, params in entries:
            f.write(json.dumps({"benchmark": bench, "params": list(params)}) + "\n")


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_1_integration_validator_launcher_wait_compare():
    """Integration: validator → expected file → launcher (empty RUN_DIR) → wait → compare."""
    print("\n--- Test 1: Integration validator→launcher→wait→compare ---")
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        bm_file = td / "results" / "benchmarks.json"
        make_benchmarks_json(bm_file, {
            "suite.Bench.time_x": {"params": [["2", "4"], ["count", "sum"]]},
        })
        results_dir = td / "results" / "machine1"
        make_result_file(results_dir / "aaaa-env.json", "aaaa0000", {
            "suite.Bench.time_x": make_param_result([1.0, 2.0, 3.0, 4.0], [["2","4"],["count","sum"]]),
        }, date=1000)
        make_result_file(results_dir / "bbbb-env.json", "bbbb1111", {
            "suite.Bench.time_x": make_param_result([0.5, 1.0, 1.5, 2.0], [["2","4"],["count","sum"]]),
        }, date=2000)

        run_dir = td / "runs" / "run-001"
        expected_file = td / "runs" / "run-001.expected-cases.jsonl"

        # Step 1: validator writes expected file (does NOT create run_dir)
        ec, out, err = run_python("validate-asv-selection.py",
            "--benchmarks-file", str(bm_file),
            "--output-file", str(expected_file),
            "continuous", "-b", "suite.Bench.time_x")
        assert_eq(ec, 0, "validator exits 0", err.strip())
        assert_eq(expected_file.is_file(), True, "expected file written")
        assert_eq(run_dir.exists(), False, "validator does NOT create run_dir")

        # Step 2: launcher uses fresh empty run_dir (no conflict)
        # Create a fake 'asv' in PATH so the background process can run
        fake_bin = td / "fake-bin"
        fake_bin.mkdir()
        fake_asv = fake_bin / "asv"
        fake_asv.write_text("#!/usr/bin/env bash\necho 'fake asv ran'\nexit 0\n", encoding="utf-8")
        fake_asv.chmod(0o755)
        test_env = dict(os.environ)
        test_env["PATH"] = str(fake_bin) + os.pathsep + test_env.get("PATH", "")

        ec, out, err = run_bash("asv-background.sh", str(run_dir), "run", "-b", "suite.Bench.time_x", env=test_env)
        assert_eq(ec, 0, "launcher exits 0 with fresh empty run_dir", err.strip())
        time.sleep(1)
        assert_eq((run_dir / "pid").is_file(), True, "pid file created")

        # Step 3: compare uses expected file
        ec, out, err = run_python("compare-asv.py",
            "--results-dir", str(results_dir),
            "--baseline", "aaaa", "--candidate", "bbbb",
            "--expected-cases-file", str(expected_file))
        assert_eq(ec, 0, "compare exits 0 (all improvements)", err.strip()[:200])
        assert_contains(out, "suite.Bench.time_x", "benchmark in table")


def test_2_exact_base_selector_parametrized():
    """Test 2: ^suite\\.Bench\\.time_x$ on parameterized benchmark → zero matches (like ASV)."""
    print("\n--- Test 2: exact base selector on parameterized benchmark ---")
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        bm_file = td / "benchmarks.json"
        make_benchmarks_json(bm_file, {
            "suite.Bench.time_x": {"params": [["2", "4"], ["count", "sum"]]},
        })
        ec, out, err = run_python("validate-asv-selection.py",
            "--benchmarks-file", str(bm_file),
            "--output-file", str(td / "expected.jsonl"),
            "continuous", "-b", r"^suite\.Bench\.time_x$")
        assert_eq(ec, 1, "exact base selector zero-matches parametrized benchmark", err.strip()[:200])


def test_3_single_case_selector():
    """Test 3: time_x\\(2, count\\)$ → matches only one param case.

    ASV format: benchmark.name(param1, param2) with raw values joined by ", ".
    So params ["2","count"] → label "suite.Bench.time_x(2, count)".
    """
    print("\n--- Test 3: single case selector ---")
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        bm_file = td / "benchmarks.json"
        make_benchmarks_json(bm_file, {
            "suite.Bench.time_x": {"params": [["2", "4"], ["count", "sum"]]},
        })
        out_file = td / "expected.jsonl"
        ec, out, err = run_python("validate-asv-selection.py",
            "--benchmarks-file", str(bm_file),
            "--output-file", str(out_file),
            "continuous", "-b", r"time_x\(2, count\)$")
        assert_eq(ec, 0, "single case selector matches", err.strip()[:200])
        content = out_file.read_text(encoding="utf-8")
        lines = [l for l in content.strip().split("\n") if l]
        assert_eq(len(lines), 1, "exactly 1 expected case", content)


def test_4_broad_selector():
    """Test 4: time_x → matches all param cases."""
    print("\n--- Test 4: broad selector ---")
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        bm_file = td / "benchmarks.json"
        make_benchmarks_json(bm_file, {
            "suite.Bench.time_x": {"params": [["2", "4"], ["count", "sum"]]},
        })
        out_file = td / "expected.jsonl"
        ec, out, err = run_python("validate-asv-selection.py",
            "--benchmarks-file", str(bm_file),
            "--output-file", str(out_file),
            "continuous", "-b", "time_x")
        assert_eq(ec, 0, "broad selector matches", err.strip())
        lines = [l for l in out_file.read_text(encoding="utf-8").strip().split("\n") if l]
        assert_eq(len(lines), 4, "4 expected cases (2x2 params)", str(lines))


def test_5_invalid_regex_fails():
    """Test 5: invalid regex → exit 1 (no literal fallback)."""
    print("\n--- Test 5: invalid regex fails ---")
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        bm_file = td / "benchmarks.json"
        make_benchmarks_json(bm_file, {"suite.Bench.time_x": {}})
        ec, out, err = run_python("validate-asv-selection.py",
            "--benchmarks-file", str(bm_file),
            "--output-file", str(td / "expected.jsonl"),
            "continuous", "-b", "[invalid(regex")
        assert_eq(ec, 1, "invalid regex exits 1", err.strip()[:200])
        assert_contains(err, "invalid regex", "error mentions invalid regex")


def test_6_missing_from_candidate():
    """Test 6: expected case present in baseline, missing from candidate → exit 2."""
    print("\n--- Test 6: missing from candidate → exit 2 ---")
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        results = td / "results" / "m1"
        make_result_file(results / "aaaa-env.json", "aaaa0000", {
            "suite.A": make_simple_result(1.0),
            "suite.B": make_simple_result(2.0),
        }, date=1000)
        make_result_file(results / "bbbb-env.json", "bbbb1111", {
            "suite.A": make_simple_result(0.5),
            # suite.B missing from candidate
        }, date=2000)
        expected = td / "expected.jsonl"
        write_jsonl(expected, [("suite.A", ()), ("suite.B", ())])
        ec, out, err = run_python("compare-asv.py",
            "--results-dir", str(results),
            "--baseline", "aaaa", "--candidate", "bbbb",
            "--expected-cases-file", str(expected))
        assert_eq(ec, 2, "missing from candidate → exit 2", err.strip()[:200])
        assert_contains(err, "CANDIDATE", "error mentions CANDIDATE")


def test_7_missing_from_baseline():
    """Test 7: expected case present in candidate, missing from baseline → exit 2."""
    print("\n--- Test 7: missing from baseline → exit 2 ---")
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        results = td / "results" / "m1"
        make_result_file(results / "aaaa-env.json", "aaaa0000", {
            "suite.A": make_simple_result(1.0),
            # suite.B missing from baseline
        }, date=1000)
        make_result_file(results / "bbbb-env.json", "bbbb1111", {
            "suite.A": make_simple_result(0.5),
            "suite.B": make_simple_result(2.0),
        }, date=2000)
        expected = td / "expected.jsonl"
        write_jsonl(expected, [("suite.A", ()), ("suite.B", ())])
        ec, out, err = run_python("compare-asv.py",
            "--results-dir", str(results),
            "--baseline", "aaaa", "--candidate", "bbbb",
            "--expected-cases-file", str(expected))
        assert_eq(ec, 2, "missing from baseline → exit 2", err.strip()[:200])
        assert_contains(err, "BASELINE", "error mentions BASELINE")


def test_8_expected_file_not_exist():
    """Test 8: expected file doesn't exist → exit 2."""
    print("\n--- Test 8: expected file not exist → exit 2 ---")
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        results = td / "results" / "m1"
        make_result_file(results / "aaaa-env.json", "aaaa0000", {"suite.A": make_simple_result(1.0)})
        make_result_file(results / "bbbb-env.json", "bbbb1111", {"suite.A": make_simple_result(0.5)})
        ec, out, err = run_python("compare-asv.py",
            "--results-dir", str(results),
            "--baseline", "aaaa", "--candidate", "bbbb",
            "--expected-cases-file", str(td / "nonexistent.jsonl"))
        assert_eq(ec, 2, "nonexistent expected file → exit 2", err.strip()[:200])


def test_9_expected_file_empty():
    """Test 9: expected file empty → exit 2."""
    print("\n--- Test 9: empty expected file → exit 2 ---")
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        results = td / "results" / "m1"
        make_result_file(results / "aaaa-env.json", "aaaa0000", {"suite.A": make_simple_result(1.0)})
        make_result_file(results / "bbbb-env.json", "bbbb1111", {"suite.A": make_simple_result(0.5)})
        expected = td / "empty.jsonl"
        expected.write_text("", encoding="utf-8")
        ec, out, err = run_python("compare-asv.py",
            "--results-dir", str(results),
            "--baseline", "aaaa", "--candidate", "bbbb",
            "--expected-cases-file", str(expected))
        assert_eq(ec, 2, "empty expected file → exit 2", err.strip()[:200])


def test_10_jsonl_param_with_comma():
    """Test 10: JSONL with param containing comma."""
    print("\n--- Test 10: JSONL param with comma ---")
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        bm_file = td / "benchmarks.json"
        # Single axis with one value containing a comma
        make_benchmarks_json(bm_file, {
            "suite.Bench.time_x": {"params": [["a, b"]]},
        })
        out_file = td / "expected.jsonl"
        ec, out, err = run_python("validate-asv-selection.py",
            "--benchmarks-file", str(bm_file),
            "--output-file", str(out_file),
            "continuous", "-b", "time_x")
        assert_eq(ec, 0, "validator handles param with comma", err.strip())
        lines = [l for l in out_file.read_text(encoding="utf-8").strip().split("\n") if l]
        assert_eq(len(lines), 1, "1 case", lines[0])
        obj = json.loads(lines[0])
        assert_eq(obj["params"], ["a, b"], "param preserves comma", str(obj))


def test_11_cr_selector_normalized():
    """Test 11: CR-contaminated selector normalized by validator."""
    print("\n--- Test 11: CR selector normalized ---")
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        bm_file = td / "benchmarks.json"
        make_benchmarks_json(bm_file, {"suite.Bench.time_x": {}})
        cr_selector = "suite.Bench.time_x\r"
        ec, out, err = run_python("validate-asv-selection.py",
            "--benchmarks-file", str(bm_file),
            "--output-file", str(td / "expected.jsonl"),
            "continuous", "-b", cr_selector)
        assert_eq(ec, 0, "CR selector normalized and matched", err.strip()[:200])


def test_12_stale_case_excluded():
    """Test 12: stale unrelated case not in report when expected-cases used."""
    print("\n--- Test 12: stale case excluded ---")
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        results = td / "results" / "m1"
        make_result_file(results / "aaaa-env.json", "aaaa0000", {
            "suite.fresh": make_simple_result(1.0),
            "suite.stale": make_simple_result(99.0),
        }, date=1000)
        make_result_file(results / "bbbb-env.json", "bbbb1111", {
            "suite.fresh": make_simple_result(0.5),
            "suite.stale": make_simple_result(99.0),  # stale
        }, date=2000)
        expected = td / "expected.jsonl"
        write_jsonl(expected, [("suite.fresh", ())])
        ec, out, err = run_python("compare-asv.py",
            "--results-dir", str(results),
            "--baseline", "aaaa", "--candidate", "bbbb",
            "--expected-cases-file", str(expected))
        assert_not_contains(out, "stale", "stale benchmark excluded")
        assert_contains(out, "fresh", "fresh benchmark included")


def test_13_comparable_pass():
    """Test 13: comparable pass → exit 0."""
    print("\n--- Test 13: comparable pass → exit 0 ---")
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        results = td / "results" / "m1"
        make_result_file(results / "aaaa-env.json", "aaaa0000", {"suite.A": make_simple_result(1.0)})
        make_result_file(results / "bbbb-env.json", "bbbb1111", {"suite.A": make_simple_result(0.5)})
        ec, out, err = run_python("compare-asv.py",
            "--results-dir", str(results),
            "--baseline", "aaaa", "--candidate", "bbbb",
            "--threshold", "5")
        assert_eq(ec, 0, "pass → exit 0", err.strip()[:200])


def test_14_comparable_regression():
    """Test 14: comparable regression → exit 1."""
    print("\n--- Test 14: comparable regression → exit 1 ---")
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        results = td / "results" / "m1"
        make_result_file(results / "aaaa-env.json", "aaaa0000", {"suite.A": make_simple_result(1.0)})
        make_result_file(results / "bbbb-env.json", "bbbb1111", {"suite.A": make_simple_result(2.0)})
        ec, out, err = run_python("compare-asv.py",
            "--results-dir", str(results),
            "--baseline", "aaaa", "--candidate", "bbbb",
            "--threshold", "5")
        assert_eq(ec, 1, "regression → exit 1", err.strip()[:200])
        assert_contains(out, "REGRESSION", "table shows REGRESSION")


def test_15_unreliable_exit_2():
    """Test 15: NOT_COMPARABLE (one side null) → exit 2."""
    print("\n--- Test 15: unreliable → exit 2 ---")
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        results = td / "results" / "m1"
        make_result_file(results / "aaaa-env.json", "aaaa0000", {"suite.A": make_simple_result(1.0)})
        # candidate result is null (failed)
        make_result_file(results / "bbbb-env.json", "bbbb1111", {"suite.A": make_simple_result(None)})
        ec, out, err = run_python("compare-asv.py",
            "--results-dir", str(results),
            "--baseline", "aaaa", "--candidate", "bbbb",
            "--threshold", "5")
        assert_eq(ec, 2, "NOT_COMPARABLE → exit 2", err.strip()[:200])


def test_16_done_missing_exit_code():
    """Test 11 (original): done but missing exit_code → corrupt-run."""
    print("\n--- Test 16: done but no exit_code → corrupt-run ---")
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        run_dir = td / "run"
        run_dir.mkdir()
        (run_dir / "pid").write_text("12345")
        (run_dir / "done").touch()
        ec, out, err = run_bash("wait-for-asv.sh",
            "--via", "env", "--run-dir", str(run_dir), "--poll-interval", "1")
        assert_eq(ec, 5, "corrupt-run → exit 5", err.strip()[:200])
        assert_contains(out, "corrupt-run", "output mentions corrupt-run")


def test_17_transport_not_run_dir():
    """Test 12 (original): transport failure → exit 5, not exit 2."""
    print("\n--- Test 17: transport failure → exit 5 ---")
    with tempfile.TemporaryDirectory() as td:
        ec, out, err = run_bash("wait-for-asv.sh",
            "--via", "ssh nonexistent-host-xyz-99999",
            "--run-dir", "/tmp/test",
            "--poll-interval", "1", "--timeout", "5", timeout=15)
        assert_eq(ec, 5, "transport failure → exit 5", f"ec={ec} err={err[:100]}")
        assert_contains(err, "transport", "error mentions transport")


def test_18_blank_via_exit_64():
    """Test: blank --via → exit 64."""
    print("\n--- Test 18: blank --via → exit 64 ---")
    with tempfile.TemporaryDirectory() as td:
        ec, out, err = run_bash("wait-for-asv.sh",
            "--via", "", "--run-dir", "/tmp/test")
        assert_eq(ec, 64, "blank --via → exit 64", err.strip()[:200])


def test_19_invalid_jsonl_expected():
    """Test: invalid JSONL expected file → exit 2."""
    print("\n--- Test 19: invalid JSONL → exit 2 ---")
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        results = td / "results" / "m1"
        make_result_file(results / "aaaa-env.json", "aaaa0000", {"suite.A": make_simple_result(1.0)})
        make_result_file(results / "bbbb-env.json", "bbbb1111", {"suite.A": make_simple_result(0.5)})
        expected = td / "bad.jsonl"
        expected.write_text("this is not valid json\n", encoding="utf-8")
        ec, out, err = run_python("compare-asv.py",
            "--results-dir", str(results),
            "--baseline", "aaaa", "--candidate", "bbbb",
            "--expected-cases-file", str(expected))
        assert_eq(ec, 2, "invalid JSONL → exit 2", err.strip()[:200])


def test_20_two_selectors_one_zero():
    """Test 1 (original): two selectors, one zero-match → exit 1."""
    print("\n--- Test 20: two selectors, one zero-match ---")
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        bm_file = td / "benchmarks.json"
        make_benchmarks_json(bm_file, {
            "suite.A.time_x": {"params": [["2", "4"]]},
            "suite.B.time_y": {"params": []},
        })
        ec, out, err = run_python("validate-asv-selection.py",
            "--benchmarks-file", str(bm_file),
            "--output-file", str(td / "expected.jsonl"),
            "continuous", "-b", "time_x", "-b", "NonExistent")
        assert_eq(ec, 1, "one zero-match selector → exit 1", err.strip()[:200])


def test_21_multi_selector_all_match():
    """Test 5 (original): multiple valid selectors all match → exit 0."""
    print("\n--- Test 21: multiple valid selectors all match ---")
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        bm_file = td / "benchmarks.json"
        make_benchmarks_json(bm_file, {
            "suite.A.time_x": {"params": [["2"]]},
            "suite.B.time_y": {"params": []},
        })
        ec, out, err = run_python("validate-asv-selection.py",
            "--benchmarks-file", str(bm_file),
            "--output-file", str(td / "expected.jsonl"),
            "continuous", "-b", "time_x", "-b", "time_y")
        assert_eq(ec, 0, "all selectors match → exit 0", err.strip()[:200])


def test_22_launcher_rejects_nonempty_dir():
    """Test: launcher rejects non-empty run directory."""
    print("\n--- Test 22: launcher rejects non-empty run_dir ---")
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        run_dir = td / "run"
        run_dir.mkdir()
        (run_dir / "stale_done").touch()
        ec, out, err = run_bash("asv-background.sh", str(run_dir), "run")
        assert_eq(ec, 1, "non-empty run_dir → exit 1", err.strip()[:200])


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    print("=" * 60)
    print("perf-bench-loop self-contained behavioral tests")
    print("=" * 60)

    tests = [
        test_1_integration_validator_launcher_wait_compare,
        test_2_exact_base_selector_parametrized,
        test_3_single_case_selector,
        test_4_broad_selector,
        test_5_invalid_regex_fails,
        test_6_missing_from_candidate,
        test_7_missing_from_baseline,
        test_8_expected_file_not_exist,
        test_9_expected_file_empty,
        test_10_jsonl_param_with_comma,
        test_11_cr_selector_normalized,
        test_12_stale_case_excluded,
        test_13_comparable_pass,
        test_14_comparable_regression,
        test_15_unreliable_exit_2,
        test_16_done_missing_exit_code,
        test_17_transport_not_run_dir,
        test_18_blank_via_exit_64,
        test_19_invalid_jsonl_expected,
        test_20_two_selectors_one_zero,
        test_21_multi_selector_all_match,
        test_22_launcher_rejects_nonempty_dir,
    ]

    for t in tests:
        try:
            t()
        except Exception as e:
            failed += 1
            msg = f"  ERROR: {t.__name__} — {e}"
            print(msg)
            errors.append(msg)

    print("\n" + "=" * 60)
    print(f"Results: {passed} passed, {failed} failed, {len(tests)} tests")
    if errors:
        print("\nFailures:")
        for e in errors:
            print(e)
    print("=" * 60)
    sys.exit(1 if failed else 0)
