#!/usr/bin/env bash
#
# config.example.sh — Template for project-specific perf-bench-loop configuration.
#
# Copy this file to <project-root>/.perf-bench-loop/config.sh and fill in the
# values for your project. The config is sourced (bash) by publish_candidate.sh,
# preflight.sh, and run_remote_asv.sh. It is NOT committed to the project repo
# (add .perf-bench-loop/ to .git/info/exclude or .gitignore).
#
# Fields marked [required] must be non-empty. Fields marked [optional] may be
# left empty to disable that feature.
#

# ── Publication gate ───────────────────────────────────────────────────
# Branch and remote for commit/push via publish_candidate.sh.

PBL_BRANCH="dev"                              # [required] local + remote branch
PBL_REMOTE="origin"                           # [required] git remote name

# Paths that publish_candidate.sh must refuse to stage, even if explicitly
# passed via --path. Typically local Agent configuration, docs that should
# stay local, or any project-internal path that must never be published.
# Listed as repo-relative path prefixes (matched against the start of the
# staged path).
PBL_PROTECTED_PATHS=(
    "AGENTS.md"
    "INSTALL.md"
    "VALIDATION.md"
    ".codex"
    ".opencode"
    "tools/agent"
)

# ── Remote environment ─────────────────────────────────────────────────
# How to reach the benchmark machine. If PBL_CONTAINER is non-empty, the
# exec prefix becomes "ssh $PBL_SSH_HOST docker exec -i $PBL_CONTAINER".
# If empty, it is just "ssh $PBL_SSH_HOST".

PBL_SSH_HOST="kpserver"                       # [required] SSH host
PBL_CONTAINER="ericheee-cpu200-203"           # [optional] Docker container name
PBL_REMOTE_REPO="/home/user/project"          # [required] repo path on the benchmark machine
PBL_ASV_DIR="/home/user/project/asv_bench"    # [required] ASV directory on the benchmark machine
PBL_LOG_DIR="/home/user/asv-logs"             # [required] log directory OUTSIDE the repo

# ── Environment activation ─────────────────────────────────────────────
# All activation is ephemeral (sourced inside one SSH command, never written
# to activate.d / bashrc / profiles). Leave empty to skip that step.

PBL_CONDA_EXE="/opt/miniforge3/bin/conda"     # [optional] conda executable path
PBL_CONDA_ENV="myenv"                         # [optional] conda environment name
PBL_TOOLCHAIN_ENABLE="/opt/rh/gcc-toolset-12/enable"  # [optional] toolchain enable script
PBL_ENV_EXPORTS=(                             # [optional] extra env vars to export
    "OPENBLAS_NUM_THREADS=4"
    "NUMEXPR_NUM_THREADS=4"
    "MKL_NUM_THREADS=4"
)

# ── Environment validation ─────────────────────────────────────────────
# preflight.sh checks these after activation. Leave empty to skip a check.

PBL_EXPECTED_GCC_MAJOR="12"                   # [optional] required GCC major version
PBL_EXPECTED_ARCH="aarch64"                   # [optional] required architecture (uname -m)
PBL_REQUIRED_TOOLS=(python asv meson ninja build)  # [optional] tools that must be on PATH

# ── Benchmark suites ───────────────────────────────────────────────────
# Named selector groups. run_remote_asv.sh --suite <name> expands the
# corresponding PBL_SUITES_<NAME> array into -b selectors.
# Define one array per suite you want available. The names "owned",
# "groupby", "rolling" below are examples — use whatever names your
# project needs. Each entry is an ASV benchmark selector (regex passed
# to `asv continuous -b`).

PBL_SUITES_OWNED=(
    "suite.time_foo"
    "suite.time_bar"
)
PBL_SUITES_GROUPBY=(
    "suite.time_foo"
)
PBL_SUITES_ROLLING=(
    "suite.time_bar"
)

# ── ASV comparison ─────────────────────────────────────────────────────

PBL_FACTOR="1.05"                             # [required] asv continuous/compare factor
PBL_THRESHOLD="5"                             # [optional] compare-asv.py regression threshold (%)
PBL_POLICY="no-regression"                    # [optional] no-regression | require-improvement

# ── Remote mirror synchronization ──────────────────────────────────────
# When 1, publish_candidate.sh and preflight.sh align the remote validation
# mirror (git fetch + switch + pull --ff-only) before testing. Set to 0 for
# historical-commit diagnostics where you don't want to move the remote branch.

PBL_SYNC_REMOTE="1"                           # [required] 1 = sync mirror, 0 = skip
