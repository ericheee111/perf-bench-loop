# ASV Coverage Discipline

Generic methodology for validating performance changes with ASV. This is
project-agnostic — it defines *how* to validate rigorously once you know
*what* to validate. Project-specific benchmark scope (which selectors, how
many cases, which are "owned") belongs in the project's `AGENTS.md` or
equivalent.

## Coverage expansion order

When you change shared code, validate in this order:

1. **one exact affected parameter case** (fastest feedback);
2. **the affected method/function family**;
3. **the complete affected owned selector**;
4. **all owned selectors** when shared infrastructure changed;
5. **related non-owned paths** that reuse the changed implementation.

Never claim completion from a subset. If a change affects shared code,
steps 3–5 are mandatory, not optional.

## Parameter-level rigor

- Parameterized benchmarks produce one case per parameter combination.
  `compare-asv.py` reports each combination as its own row — read each one.
- **Do not merge cases into an average.** A 20% regression on one parameter
  masked by improvements on others is still a regression. Report each
  affected case individually with its ratio and status.
- A stable related regression around 10% normally rejects a patch. Smaller
  broad regressions may also reject. Treat near-noise results as
  inconclusive and repeat under identical conditions.

## Threshold semantics

At factor 1.05 (5% threshold), ASV reports "no significant change detected"
when no case crosses the threshold. This means *no configured-threshold-level
change was detected* — it does **not** prove zero performance impact.

Say "no significant change detected," not "zero impact" or "no change."

## Specialization safety (when applicable)

If the project uses exact-identity callable fast paths (e.g.
`function is builtins.sum`), the generic callback path (lambdas, wrappers,
partials, same-named functions) must remain unoptimized. Specialization
through strict identity checks only — never through name matching, bytecode
inspection, or source-text comparison.

This is a project-specific concern. See the project's `AGENTS.md` for
whether it applies and what the constraints are.

## No benchmark-specific hacks

Never optimize by detecting:

- benchmark class or method names;
- exact benchmark sizes;
- fixed random seeds;
- known benchmark object identities;
- exact benchmark values;
- lambda bytecode or source text.

Valid specialization may use generic properties such as dtype, number of
columns, contiguity, mask presence, value range or density, operation kind,
or API flags like `skipna`/`min_count`/`min_periods`.

Every specialized path must fall back to the existing implementation when
its conditions are not satisfied.

## Reporting contract

Every validation report should include:

- baseline and candidate commits (full SHAs);
- exact selectors and benchmark commands run;
- per-case before, after, ratio, and status (not merged averages);
- regressions and improvements, listed individually;
- rejected approaches (if any);
- remaining risks.

If the project requires specific report formatting (e.g. interim hardware
labels, manual-validation-pending suffixes), see the project's `AGENTS.md`.
The scripts in this skill produce machine-parseable output; the agent adds
project-specific annotations when composing the human-facing report.
