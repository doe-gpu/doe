#!/usr/bin/env python3
"""Tests for native backend coverage matrix checks."""

from __future__ import annotations

import json
import hashlib
import tempfile
import unittest
import copy
from pathlib import Path

from bench.tools import check_native_backend_coverage_matrix as coverage


REPO_ROOT = Path(__file__).resolve().parents[2]
MATRIX_PATH = REPO_ROOT / "config" / "native-backend-coverage-matrix.json"


def _load() -> dict:
    return json.loads(MATRIX_PATH.read_text(encoding="utf-8"))


def _covered() -> dict:
    payload = _load()
    payload['rows'][0].update(status='covered', reasonCode='', evidenceSha256='a' * 64)
    return payload


class NativeBackendCoverageTests(unittest.TestCase):
    def test_native_backend_coverage_matrix_passes_check(self) -> None:
        assert coverage.check_matrix(_load()) == []
        assert coverage.check_matrix(_load(), REPO_ROOT) == []


    def test_native_backend_coverage_matrix_requires_all_rows(self) -> None:
        payload = _load()
        payload["rows"] = [
            row for row in payload["rows"] if not (row["backend"] == "doe_d3d12" and row["coverageClass"] == "tails")
        ]

        assert {
            "code": "missing_coverage_row",
            "path": "rows",
            "message": "missing coverage row doe_d3d12:tails",
        } in coverage.check_matrix(payload)


    def test_native_backend_coverage_matrix_requires_evidence_for_covered_rows(self) -> None:
        payload = _covered()
        payload["rows"][0]["evidencePath"] = ""

        assert {
            "code": "covered_row_missing_evidence",
            "path": "rows[0].evidencePath",
            "message": "covered rows require evidencePath",
        } in coverage.check_matrix(payload)


    def test_native_backend_coverage_matrix_requires_reason_for_diagnostic_rows(self) -> None:
        payload = _load()
        payload["rows"][3]["reasonCode"] = ""

        assert {
            "code": "diagnostic_row_missing_reason",
            "path": "rows[3].reasonCode",
            "message": "diagnostic and missing rows require reasonCode",
        } in coverage.check_matrix(payload)


    def test_native_backend_coverage_matrix_verifies_evidence_file_exists(self) -> None:
        payload = _covered()
        payload["rows"][0]["evidencePath"] = "reports/missing-native-evidence.json"

        assert {
            "code": "evidence_file_missing",
            "path": "rows[0].evidencePath",
            "message": "evidence file not found: reports/missing-native-evidence.json",
        } in coverage.check_matrix(payload, REPO_ROOT)


    def test_native_backend_coverage_matrix_rejects_unsafe_evidence_path(self) -> None:
        payload = _covered()
        payload["rows"][0]["evidencePath"] = "/tmp/native-upload.json"

        assert {
            "code": "unsafe_evidence_path",
            "path": "rows[0].evidencePath",
            "message": "evidencePath must be repo-relative",
        } in coverage.check_matrix(payload, REPO_ROOT)


    def test_native_backend_coverage_matrix_verifies_evidence_kind(self) -> None:
        payload = _covered()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / 'receipt.json'
            path.write_text(json.dumps({'artifactKind': 'native_pipeline_cache_receipts'}))
            payload['rows'][0].update(evidencePath=path.name,
                                      evidenceSha256=hashlib.sha256(path.read_bytes()).hexdigest())
            failures = coverage.check_matrix(payload, root)
        assert any(item['code'] == 'evidence_artifact_kind_mismatch' for item in failures)


    def test_native_backend_coverage_matrix_rejects_schema_examples_without_file_probe(self) -> None:
        payload = _covered()
        for path in ['examples/native-upload-path-receipts.sample.json', 'reports/native-upload.sample.json']:
            payload['rows'][0]['evidencePath'] = path
            assert any(item['code'] == 'example_is_not_evidence' for item in coverage.check_matrix(payload))


    def test_native_backend_coverage_matrix_rejects_unbound_and_renamed_examples(self) -> None:
        payload = _covered()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / 'receipt.json'
            path.write_bytes((REPO_ROOT / 'examples/native-upload-path-receipts.sample.json').read_bytes())
            payload['rows'][0]['evidencePath'] = path.name
            failures = coverage.check_matrix(payload, root)
            assert any('hash mismatch' in item['message'] for item in failures)
            payload['rows'][0]['evidenceSha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
            failures = coverage.check_matrix(payload, root)
            assert any(item['code'] == 'evidence_execution_invalid' for item in failures)

    def test_bound_execution_requires_backend_success_and_retained_work(self) -> None:
        payload = _load()
        row = next(item for item in payload['rows']
                   if item['backend'] == 'doe_vulkan' and item['coverageClass'] == 'compute')
        receipt = json.loads((REPO_ROOT / 'examples/run-receipt.sample.json').read_text())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / 'runtime.bin'
            binary.write_bytes(b'unit-test executable identity')
            receipt['runtimeIdentity'].update(binaryPath=binary.name,
                binarySha256=hashlib.sha256(binary.read_bytes()).hexdigest())
            meta = dict(traceVersion=1, seqMax=0, rowCount=1, hash='0x1',
                        previousHash='0x9e3779b97f4a7c15', executionBackend='doe_vulkan',
                        fallbackUsed=False, executionRowCount=1, executionSuccessCount=1,
                        executionErrorCount=0, executionSkippedCount=0, executionUnsupportedCount=0,
                        executionDispatchCount=1, executionSubmitCount=1)
            (root / 'trace.meta.json').write_text(json.dumps(meta))
            trace_row = {key: meta[key] for key in ['traceVersion', 'hash', 'previousHash']}
            trace_row.update(module='unit-test', opCode='dispatch', seq=0,
                             timestampMonoNs=0, command='kernel_dispatch',
                             executionStatus='ok', executionBackend='doe_vulkan',
                             executionDispatchCount=1, executionSubmitCount=1)
            (root / 'trace.jsonl').write_text(json.dumps(trace_row) + '\n')
            receipt['samples'][0].update(traceMeta=meta,
                traceArtifacts={'jsonlPath': 'trace.jsonl', 'metaPath': 'trace.meta.json'})
            path = root / 'run.json'
            def bind(value: dict) -> None:
                path.write_text(json.dumps(value))
                row.update(status='covered', reasonCode='', evidencePath=path.name,
                           evidenceSha256=hashlib.sha256(path.read_bytes()).hexdigest())
            bind(receipt)
            self.assertEqual(coverage.check_matrix(payload, root), [])
            for mutate in [
                lambda r: r['runtimeIdentity'].update(executionBackend='doe_metal'),
                lambda r: r['execution'].update(success=False),
                lambda r: r['samples'][0].update(returnCode=1),
                lambda r: r['samples'][0]['traceMeta'].update(hash='0x2'),
                lambda r: r['hostIdentity'].update(driver=''),
                lambda r: r['runtimeIdentity'].update(binarySha256='0' * 64),
            ]:
                changed = copy.deepcopy(receipt)
                mutate(changed)
                bind(changed)
                self.assertTrue(coverage.check_matrix(payload, root))
            bind(receipt)
            for field, value in [('fallbackUsed', True), ('executionRowCount', 0),
                                 ('executionSkippedCount', 1), ('executionBackend', 'doe_metal')]:
                changed = {**meta, field: value}
                (root / 'trace.meta.json').write_text(json.dumps(changed))
                self.assertTrue(coverage.check_matrix(payload, root))


if __name__ == '__main__':
    unittest.main()
