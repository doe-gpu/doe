"""Public-verification tests for Doe promotion receipts."""

from __future__ import annotations

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
    def test_ed25519_receipt_verifies_and_detects_tampering(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            key = Path(directory) / "doe-proof"
            subprocess.run(
                ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)],
                check=True,
            )
            subject = {"platform": "apple-metal", "decision": "directProtocol"}
            with patch.dict(os.environ, {"TEST_DOE_SIGNING_KEY": str(key)}):
                receipt = promotion_receipt(subject, "TEST_DOE_SIGNING_KEY")
            verify_promotion_receipt(subject, receipt)
            with self.assertRaisesRegex(LiveEvidenceError, "subject hash"):
                verify_promotion_receipt({**subject, "decision": "changed"}, receipt)


if __name__ == "__main__":
    unittest.main()
