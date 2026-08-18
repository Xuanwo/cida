import json
import pathlib
import subprocess
import tempfile
import unittest


PROJECT_ROOT = pathlib.Path(__file__).resolve().parents[3]
MERGER = PROJECT_ROOT / "scripts/e2e/merge-host-monitor-observations.py"


class HostMonitorMergeTests(unittest.TestCase):
    def test_staggered_monitors_fill_each_others_sampling_gaps(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            primary = root / "primary.jsonl"
            secondary = root / "secondary.jsonl"
            merged = root / "merged.jsonl"
            primary.write_text(
                '\n'.join(
                    json.dumps({"capturedAt": timestamp})
                    for timestamp in (
                        "2026-08-18T17:21:28.000Z",
                        "2026-08-18T17:21:31.000Z",
                    )
                )
                + "\n",
                encoding="utf-8",
            )
            secondary.write_text(
                '\n'.join(
                    json.dumps({"capturedAt": timestamp})
                    for timestamp in (
                        "2026-08-18T17:21:28.100Z",
                        "2026-08-18T17:21:29.000Z",
                        "2026-08-18T17:21:30.000Z",
                        "2026-08-18T17:21:30.900Z",
                    )
                )
                + "\n",
                encoding="utf-8",
            )

            subprocess.run(
                [str(MERGER), str(merged), str(primary), str(secondary)], check=True
            )
            timestamps = [
                json.loads(line)["capturedAt"]
                for line in merged.read_text(encoding="utf-8").splitlines()
            ]

        self.assertEqual(timestamps, sorted(timestamps))
        self.assertEqual(len(timestamps), 6)


if __name__ == "__main__":
    unittest.main()
