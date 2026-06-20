from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from bench.lib.bench_utils import load_json_object
from bench.lib.bench_utils import write_json_object


class BenchUtilsTest(unittest.TestCase):
    def test_write_json_object_uses_canonical_object_format(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "nested" / "payload.json"

            write_json_object(path, {"z": 1, "a": {"b": 2}})

            self.assertEqual(
                path.read_text(encoding="utf-8"),
                '{\n  "a": {\n    "b": 2\n  },\n  "z": 1\n}\n',
            )
            self.assertEqual(load_json_object(path), {"z": 1, "a": {"b": 2}})


if __name__ == "__main__":
    unittest.main()
