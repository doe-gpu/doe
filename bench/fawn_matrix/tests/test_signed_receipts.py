"""Public-verification tests for Doe promotion receipts."""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from bench.fawn_matrix.harness.live_evidence import (
    LiveEvidenceError,
    promotion_receipt,
    verify_promotion_receipt,
)


class SignedReceiptTest(unittest.TestCase):
    def _trust_policy(self, public_key: str, root: Path) -> Path:
        root.mkdir(parents=True, exist_ok=True)
        canonical_key = " ".join(public_key.split()[:2])
        policy = {
            "schemaVersion": 1,
            "policyId": "doe-proof-release-signers-v1",
            "policyState": "active",
            "signers": [{
                "signerId": "test-release-authority",
                "identity": "Doe test release authority",
                "publicKeySha256": hashlib.sha256(canonical_key.encode()).hexdigest(),
                "allowedReceiptKinds": ["doe-promotion-receipt-v1"],
                "allowedSubjectKinds": ["fawn-doe-platform-suite"],
                "notBefore": "2020-01-01T00:00:00Z",
                "notAfter": "2099-01-01T00:00:00Z",
                "status": "active",
            }],
            "history": [],
        }
        path = root / "trusted-signers.json"
        path.write_text(json.dumps(policy), encoding="utf-8")
        return path

    def test_ed25519_receipt_verifies_and_detects_tampering(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            key = Path(directory) / "doe-proof"
            subprocess.run(
                ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)],
                check=True,
            )
            public_key = Path(str(key) + ".pub").read_text(encoding="utf-8")
            policy = self._trust_policy(public_key, Path(directory))
            subject = {
                "reportKind": "fawn-doe-platform-suite",
                "platform": "apple-metal",
                "decision": "directProtocol",
            }
            with patch.dict(os.environ, {"TEST_DOE_SIGNING_KEY": str(key)}):
                receipt = promotion_receipt(subject, "TEST_DOE_SIGNING_KEY", policy)
            verify_promotion_receipt(subject, receipt, policy)
            with self.assertRaisesRegex(LiveEvidenceError, "subject hash"):
                verify_promotion_receipt({**subject, "decision": "changed"}, receipt, policy)

    def test_embedded_attacker_key_is_not_a_trust_anchor(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            trusted_key = root / "trusted"
            attacker_key = root / "attacker"
            for key in (trusted_key, attacker_key):
                subprocess.run(
                    ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)],
                    check=True,
                )
            trusted_policy = self._trust_policy(
                Path(str(trusted_key) + ".pub").read_text(encoding="utf-8"),
                root / "trusted-policy",
            )
            attacker_policy = self._trust_policy(
                Path(str(attacker_key) + ".pub").read_text(encoding="utf-8"),
                root / "attacker-policy",
            )
            subject = {"reportKind": "fawn-doe-platform-suite", "platform": "amd-vulkan"}
            with patch.dict(os.environ, {"TEST_DOE_SIGNING_KEY": str(attacker_key)}):
                receipt = promotion_receipt(subject, "TEST_DOE_SIGNING_KEY", attacker_policy)
            with self.assertRaisesRegex(LiveEvidenceError, "not authorized"):
                verify_promotion_receipt(subject, receipt, trusted_policy)


if __name__ == "__main__":
    unittest.main()
