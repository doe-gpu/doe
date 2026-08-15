# Ecosystem reports

This directory holds stable reviewed summaries for external-project harness
runs. Store each report under `reports/ecosystem/<actor-id>/` and validate it
against `config/ecosystem-report.schema.json`.

Reports hash-link raw receipts under `bench/out/external-projects/` or retained
governed diagnostics under `reports/benchmarks/`. The latter is appropriate
when the complete hash-bound diagnostic is itself the durable input to review;
it does not satisfy the preparation-receipt requirement for promotion.
Preserve prior reviewed reports instead of rewriting history. A registry claim
reference must name one of these reviewed reports, and a public claim may enter
`reports/claim-index.json` only after the normal correctness, equivalence,
reliability, and claim gates pass.

A report proposed for promotion must include its run's `preparation.json` in
`receipts`. The release gate verifies path containment, the referenced file
hash, the receipt's embedded content hash, passed status, actor and harness
identity, upstream commit, and claim-eligible physical support target. A
software renderer, unmatched host, failed workload, or diagnostic report
cannot be promoted by editing report prose.
