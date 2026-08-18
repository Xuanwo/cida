import importlib.util
import json
import pathlib
import tempfile
import unittest


MODULE_PATH = pathlib.Path(__file__).parents[1] / "failure_classification.py"
SPEC = importlib.util.spec_from_file_location("failure_classification", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class FailureClassificationTests(unittest.TestCase):
    def test_writes_atomic_machine_readable_classification(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "failure-classification.json"
            payload = MODULE.write_classification(
                path,
                "ui-assertion-or-crash",
                "xcui-test",
                65,
                "Inspect the xcresult and polling timeline.",
            )

            self.assertEqual(json.loads(path.read_text(encoding="utf-8")), payload)
            self.assertEqual(payload["schemaVersion"], 1)
            self.assertEqual(payload["category"], "ui-assertion-or-crash")
            self.assertEqual(payload["phase"], "xcui-test")
            self.assertEqual(payload["exitCode"], 65)
            self.assertFalse(path.with_suffix(".json.pending").exists())

    def test_rejects_unknown_category(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "unsupported failure category"):
                MODULE.write_classification(
                    pathlib.Path(directory) / "failure.json",
                    "product-maybe",
                    "unknown",
                    1,
                    "Ambiguous failures must not be overclassified.",
                )


if __name__ == "__main__":
    unittest.main()
