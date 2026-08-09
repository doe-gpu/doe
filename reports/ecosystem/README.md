# Ecosystem reports

This directory holds stable reviewed summaries for external-project harness
runs. Store each report under `reports/ecosystem/<actor-id>/` and validate it
against `config/ecosystem-report.schema.json`.

Reports hash-link their raw evidence and receipts under
`bench/out/external-projects/`. Preserve prior reviewed reports instead of
rewriting history. A registry claim reference must name one of these reviewed
reports, and a public claim may enter `reports/claim-index.json` only after the
normal correctness, equivalence, reliability, and claim gates pass.
