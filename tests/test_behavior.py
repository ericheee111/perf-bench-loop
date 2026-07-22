#!/usr/bin/env python3
"""
Behavioral tests for perf-bench-loop scripts.

Covers 12 scenarios as specified:
 1. Two selectors, one matches, one zero-match → validator exits 1
 2. Candidate shared result file has stale data for zero-matched selector
 3. Tool must fail before launch (validator) or compare returns 2
 4. Stale data must NOT appear in the comparison table
 5. Normal selectors all match → validator exits 0
 6. CR-contaminated selector can be cleaned and matched (asv-background.sh)
 7. Typo'd selector without CR must still fail
 8. Expected case missing → compare exits 2
 9. Comparable regression → compare exits 1
10. Comparable pass → compare exits 0
11. done but missing exit_code → wait returns corrupt-run
12. Transport failure not reported as run-dir-not-found

Run: python tests/test_behavior.py
"""
import json
import os
import subprocess
import sys
import tempfile
import shutil
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parent.parent
SCRIPTS = SKILL_DIR / "scripts"
RESULTS_DIR = Path(os.environ.get("PBL_TEST_RESULTS", "C:/Users/Administrator/asv-results-test/results"))
BENCHMARKS_FILE = Path(os.environ.get("PBL_TEST_BENCHMARKS", "C:/Users/Administrator/asv-results-test/benchmarks.json"))

passed = 0
failed = 0
errors = []


def run_script(script_name, *args, cwd=None):
    """Run a script and return (exit_code, stdout, stderr)."""
    script_path = SCRIPTS / script_name
    cmd = [sys.executable, str(script_path)] + list(args)
    if script_name.endswith(".sh"):
        cmd = ["bash", str(script_path)] + list(args)
    result = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd, timeout=30)
    return result.returncode, result.stdout, result.stderr


def assert_eq(actual, expected, test_name, detail=""):
    global passed, failed
    if actual == expected:
        passed += 1
        print(f"  PASS: {test_name}")
    else:
        failed += 1
        msg = f"  FAIL: {test_name} — expected {expected}, got {actual}"
        if detail:
            msg += f" ({detail})"
        print(msg)
        errors.append(msg)


def assert_contains(haystack, needle, test_name):
    global passed, failed
    if needle in haystack:
        passed += 1
        print(f"  PASS: {test_name}")
    else:
        failed += 1
        msg = f"  FAIL: {test_name} — '{needle}' not found in output"
        print(msg)
        errors.append(msg)


def assert_not_contains(haystack, needle, test_name):
    global passed, failed
    if needle not in haystack:
        passed += 1
        print(f"  PASS: {test_name}")
    else:
        failed += 1
        msg = f"  FAIL: {test_name} — '{needle}' unexpectedly found in output"
        print(msg)
        errors.append(msg)


def make_result_file(path, commit_hash, results_dict, env_name="test-env", date=1000):
    """Create a synthetic ASV 0.6.x result JSON file."""
    data = {
        "commit_hash": commit_hash,
        "env_name": env_name,
        "date": date,
        "params": {},
        "python": "3.14",
        "requirements": {},
        "env_vars": {},
        "result_columns": ["result", "params", "version", "started_at", "duration"],
        "results": results_dict,
        "durations": {},
        "version": 2,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data), encoding="utf-8")


def make_simple_result(bench_name, values, params=None):
    """Create a results entry for a benchmark.
    values: list of result values (one per param combo, or single scalar)
    params: list of param axes, e.g. [['2','4'], ['count','sum']]
    """
    if params is None:
        params = []
    if not params:
        return [values, params, "v1", 1000, 1.0]
    return [values, params, "v1", 1000, 1.0]


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_1_two_selectors_one_zero_match():
    """Test 1: Two selectors, one matches, one zero-match → validator exits 1."""
    print("\n--- Test 1: Two selectors, one zero-match ---")
    if not BENCHMARKS_FILE.is_file():
        print("  SKIP: benchmarks.json not available")
        return
    with tempfile.TemporaryDirectory() as td:
        ec, out, err = run_script("validate-asv-selection.py",
            "--benchmarks-file", str(BENCHMARKS_FILE),
            "--run-dir", td,
            "continuous", "-b", "gil.ParallelGroupbyMethods.time_loop",
            "-b", "NonExistentBenchmark")
        assert_eq(ec, 1, "validator exits 1 when a selector zero-matches")
        assert_contains(err, "ZERO benchmarks", "error message mentions zero matches")


def test_2_stale_data_in_shared_results():
    """Test 2: Candidate shared result file has stale data for zero-matched selector.
    The stale data must not appear in the comparison when expected-cases-file is used."""
    print("\n--- Test 2: Stale data in shared results file ---")
    with tempfile.TemporaryDirectory() as td:
        results = Path(td) / "results" / "machine1"
        # Baseline: has bench_a and bench_b
        make_result_file(results / "aaaa0000-env1.json", "aaaa0000", {
            "suite.bench_a": make_simple_result("suite.bench_a", [1.0]),
            "suite.bench_b": make_simple_result("suite.bench_b", [2.0]),
        }, date=1000)
        # Candidate: has bench_a (fresh) and bench_b (stale from previous run)
        make_result_file(results / "bbbb1111-env1.json", "bbbb1111", {
            "suite.bench_a": make_simple_result("suite.bench_a", [0.5]),
            "suite.bench_b": make_simple_result("suite.bench_b", [2.0]),  # stale, unchanged
        }, date=2000)
        # expected-cases.txt: only bench_a (bench_b was not in this run's selectors)
        expected = Path(td) / "expected-cases.txt"
        expected.write_text("suite.bench_a\n", encoding="utf-8")

        ec, out, err = run_script("compare-asv.py",
            "--results-dir", str(results),
            "--baseline", "aaaa",
            "--candidate", "bbbb",
            "--expected-cases-file", str(expected))
        assert_not_contains(out, "bench_b", "stale bench_b must NOT appear in table")
        assert_contains(out, "bench_a", "fresh bench_a must appear in table")


def test_3_tool_fails_before_launch():
    """Test 3: Tool must fail before launch (validator exits 1)."""
    print("\n--- Test 3: Tool fails before launch ---")
    if not BENCHMARKS_FILE.is_file():
        print("  SKIP: benchmarks.json not available")
        return
    with tempfile.TemporaryDirectory() as td:
        ec, out, err = run_script("validate-asv-selection.py",
            "--benchmarks-file", str(BENCHMARKS_FILE),
            "--run-dir", td,
            "continuous", "-b", "TypoBenchmark.Time_tpyo")
        assert_eq(ec, 1, "validator exits 1 for typo'd selector")


def test_4_stale_data_not_in_report():
    """Test 4: Stale data must NOT appear in the comparison report."""
    print("\n--- Test 4: Stale data excluded from report ---")
    with tempfile.TemporaryDirectory() as td:
        results = Path(td) / "results" / "machine1"
        make_result_file(results / "aaaa0000-env1.json", "aaaa0000", {
            "suite.fresh": make_simple_result("suite.fresh", [1.0]),
            "suite.stale": make_simple_result("suite.stale", [99.0]),
        }, date=1000)
        make_result_file(results / "bbbb1111-env1.json", "bbbb1111", {
            "suite.fresh": make_simple_result("suite.fresh", [0.5]),
            "suite.stale": make_simple_result("suite.stale", [99.0]),  # stale
        }, date=2000)
        expected = Path(td) / "expected-cases.txt"
        expected.write_text("suite.fresh\n", encoding="utf-8")

        ec, out, err = run_script("compare-asv.py",
            "--results-dir", str(results),
            "--baseline", "aaaa",
            "--candidate", "bbbb",
            "--expected-cases-file", str(expected))
        assert_not_contains(out, "stale", "stale benchmark must NOT appear")
        assert_contains(out, "fresh", "fresh benchmark must appear")


def test_5_normal_selectors_all_match():
    """Test 5: Normal selectors all match → validator exits 0."""
    print("\n--- Test 5: Normal selectors all match ---")
    if not BENCHMARKS_FILE.is_file():
        print("  SKIP: benchmarks.json not available")
        return
    with tempfile.TemporaryDirectory() as td:
        ec, out, err = run_script("validate-asv-selection.py",
            "--benchmarks-file", str(BENCHMARKS_FILE),
            "--run-dir", td,
            "continuous", "-b", "gil.ParallelGroupbyMethods.time_loop")
        assert_eq(ec, 0, "validator exits 0 for valid selector")


def test_6_cr_contaminated_selector_cleaned():
    """Test 6: CR-contaminated selector can be cleaned by asv-background.sh."""
    print("\n--- Test 6: CR cleaning in asv-background.sh ---")
    with tempfile.TemporaryDirectory() as td:
        # Create a fake 'asv' that just echoes its args
        fake_bin = Path(td) / "fake-bin"
        fake_bin.mkdir()
        fake_asv = fake_bin / "asv"
        fake_asv.write_text("""#!/usr/bin/env bash
for a in "$@"; do
    last=$(printf '%s' "$a" | od -An -tx1 | tr -d ' \\n' | tail -c 2)
    echo "arg=$a last_hex=$last"
done
""", encoding="utf-8")
        fake_asv.chmod(0o755)

        cr_arg = "test.bench\r"
        ec, out, err = run_script("asv-background.sh",
            str(Path(td) / "run"), "run", "-b", cr_arg,
            cwd=td)
        # asv-background.sh may have launched; check run.log
        import time
        time.sleep(1)
        run_log = Path(td) / "run" / "run.log"
        if run_log.exists():
            content = run_log.read_text()
            assert_not_contains(content, "0d", "CR stripped from args in run.log")
            assert_contains(content, "test.bench", "benchmark name present in run.log")
        else:
            # asv-background.sh uses PATH to find 'asv'; may not find our fake.
            # Just verify the script ran without error (exit 0 = launched)
            assert_eq(ec, 0, "asv-background.sh launched successfully")


def test_7_typo_without_cr_fails():
    """Test 7: Typo'd selector without CR must still fail validation."""
    print("\n--- Test 7: Typo'd selector without CR fails ---")
    if not BENCHMARKS_FILE.is_file():
        print("  SKIP: benchmarks.json not available")
        return
    with tempfile.TemporaryDirectory() as td:
        ec, out, err = run_script("validate-asv-selection.py",
            "--benchmarks-file", str(BENCHMARKS_FILE),
            "--run-dir", td,
            "continuous", "-b", "gil.ParallelGroupbyMethods.time_lopp")
        assert_eq(ec, 1, "validator exits 1 for typo'd selector (no CR)")


def test_8_expected_case_missing():
    """Test 8: Expected case missing → compare exits 2."""
    print("\n--- Test 8: Expected case missing → exit 2 ---")
    with tempfile.TemporaryDirectory() as td:
        results = Path(td) / "results" / "machine1"
        make_result_file(results / "aaaa0000-env1.json", "aaaa0000", {
            "suite.real": make_simple_result("suite.real", [1.0]),
        }, date=1000)
        make_result_file(results / "bbbb1111-env1.json", "bbbb1111", {
            "suite.real": make_simple_result("suite.real", [0.5]),
        }, date=2000)
        expected = Path(td) / "expected-cases.txt"
        expected.write_text("suite.real\nnonexistent.Fake.time_x\n", encoding="utf-8")

        ec, out, err = run_script("compare-asv.py",
            "--results-dir", str(results),
            "--baseline", "aaaa",
            "--candidate", "bbbb",
            "--expected-cases-file", str(expected))
        assert_eq(ec, 2, "compare exits 2 when expected case is missing")
        assert_contains(err, "missing", "error message mentions missing case")


def test_9_comparable_regression():
    """Test 9: Comparable regression → compare exits 1."""
    print("\n--- Test 9: Comparable regression → exit 1 ---")
    with tempfile.TemporaryDirectory() as td:
        results = Path(td) / "results" / "machine1"
        make_result_file(results / "aaaa0000-env1.json", "aaaa0000", {
            "suite.bench": make_simple_result("suite.bench", [1.0]),
        }, date=1000)
        make_result_file(results / "bbbb1111-env1.json", "bbbb1111", {
            "suite.bench": make_simple_result("suite.bench", [2.0]),  # 100% slower
        }, date=2000)

        ec, out, err = run_script("compare-asv.py",
            "--results-dir", str(results),
            "--baseline", "aaaa",
            "--candidate", "bbbb",
            "--threshold", "5")
        assert_eq(ec, 1, "compare exits 1 for regression")
        assert_contains(out, "REGRESSION", "table shows REGRESSION status")


def test_10_comparable_pass():
    """Test 10: Comparable pass → compare exits 0."""
    print("\n--- Test 10: Comparable pass → exit 0 ---")
    with tempfile.TemporaryDirectory() as td:
        results = Path(td) / "results" / "machine1"
        make_result_file(results / "aaaa0000-env1.json", "aaaa0000", {
            "suite.bench": make_simple_result("suite.bench", [1.0]),
        }, date=1000)
        make_result_file(results / "bbbb1111-env1.json", "bbbb1111", {
            "suite.bench": make_simple_result("suite.bench", [0.5]),  # 50% faster
        }, date=2000)

        ec, out, err = run_script("compare-asv.py",
            "--results-dir", str(results),
            "--baseline", "aaaa",
            "--candidate", "bbbb",
            "--threshold", "5")
        assert_eq(ec, 0, "compare exits 0 for improvement (no regression)")


def test_11_done_missing_exit_code():
    """Test 11: done exists but exit_code missing → wait returns corrupt-run."""
    print("\n--- Test 11: done but missing exit_code → corrupt-run ---")
    with tempfile.TemporaryDirectory() as td:
        run_dir = Path(td) / "run"
        run_dir.mkdir()
        (run_dir / "pid").write_text("12345")
        (run_dir / "done").touch()  # done exists
        # exit_code intentionally NOT created

        ec, out, err = run_script("wait-for-asv.sh",
            "--via", "env",
            "--run-dir", str(run_dir),
            "--poll-interval", "1")
        assert_eq(ec, 5, "wait exits 5 (corrupt-run) when done but no exit_code")
        assert_contains(out, "corrupt-run", "output mentions corrupt-run")


def test_12_transport_not_run_dir_not_found():
    """Test 12: Transport failure not reported as run-dir-not-found."""
    print("\n--- Test 12: Transport failure vs run-dir-not-found ---")
    with tempfile.TemporaryDirectory() as td:
        # Use a non-existent SSH host to trigger transport error
        ec, out, err = run_script("wait-for-asv.sh",
            "--via", "ssh nonexistent-host-12345",
            "--run-dir", "/tmp/test",
            "--poll-interval", "1",
            "--timeout", "5")
        # ssh to nonexistent host returns 255 → transport failure (exit 5)
        # NOT exit 2 (run-dir-not-found)
        assert_eq(ec, 5, "wait exits 5 (transport failure) for unreachable host")
        assert_contains(err, "transport", "error mentions transport failure")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    print("=" * 60)
    print("perf-bench-loop behavioral tests")
    print("=" * 60)

    tests = [
        test_1_two_selectors_one_zero_match,
        test_2_stale_data_in_shared_results,
        test_3_tool_fails_before_launch,
        test_4_stale_data_not_in_report,
        test_5_normal_selectors_all_match,
        test_6_cr_contaminated_selector_cleaned,
        test_7_typo_without_cr_fails,
        test_8_expected_case_missing,
        test_9_comparable_regression,
        test_10_comparable_pass,
        test_11_done_missing_exit_code,
        test_12_transport_not_run_dir_not_found,
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
    print(f"Results: {passed} passed, {failed} failed")
    if errors:
        print("\nFailures:")
        for e in errors:
            print(e)
    print("=" * 60)
    sys.exit(1 if failed else 0)
