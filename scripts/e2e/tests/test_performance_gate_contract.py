import importlib.util
import pathlib
import tempfile
import unittest


PROJECT_ROOT = pathlib.Path(__file__).resolve().parents[3]
GATE_MODULE_PATH = PROJECT_ROOT / "scripts/e2e/run-gate.py"
DISPLAY_MODULE_PATH = PROJECT_ROOT / "scripts/e2e/check-display-readiness.py"


def load_gate_module():
    spec = importlib.util.spec_from_file_location("cida_run_gate", GATE_MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_display_module():
    spec = importlib.util.spec_from_file_location(
        "cida_display_readiness", DISPLAY_MODULE_PATH
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class PerformanceGateContractTests(unittest.TestCase):
    def test_display_preflight_requires_an_awake_active_120hz_screen(self):
        display_module = load_display_module()
        report = display_module.evaluate_screens(
            [
                {
                    "name": "Sleeping ProMotion",
                    "displayID": 1,
                    "maximumFramesPerSecond": 120,
                    "online": True,
                    "active": False,
                    "asleep": True,
                },
                {
                    "name": "Active Studio Display",
                    "displayID": 2,
                    "maximumFramesPerSecond": 60,
                    "online": True,
                    "active": True,
                    "asleep": False,
                },
            ],
            120,
        )

        self.assertFalse(report["passed"])
        self.assertEqual(report["failureCategory"], "infrastructure")
        self.assertEqual(report["qualifiedDisplayIDs"], [])

    def test_display_preflight_accepts_an_awake_active_120hz_screen(self):
        display_module = load_display_module()
        report = display_module.evaluate_screens(
            [
                {
                    "name": "ProMotion",
                    "displayID": 7,
                    "maximumFramesPerSecond": 120,
                    "online": True,
                    "active": True,
                    "asleep": False,
                }
            ],
            120,
        )

        self.assertTrue(report["passed"])
        self.assertIsNone(report["failureCategory"])
        self.assertEqual(report["qualifiedDisplayIDs"], [7])

    def test_expensive_release_work_starts_after_display_preflight(self):
        source = (PROJECT_ROOT / "scripts/e2e/run-gate.py").read_text(encoding="utf-8")
        preflight = source.index("gate.run_performance_environment_preflight()")
        mutation_catalog = source.index('"mutation-catalog"')
        self.assertLess(preflight, mutation_catalog)

    def test_pr_proxy_names_every_bounded_rendering_invariant(self):
        source = (PROJECT_ROOT / "scripts/e2e/run-performance-proxies.sh").read_text(
            encoding="utf-8"
        )
        expected_tests = (
            "LongResultUsesIncrementalNaturalTextLayoutWithoutNestedScrolling",
            "HighFrequencyResultUpdatesCoalesceNaturalHeightLayout",
            "ComposerVirtualizesLargeDocumentAndLoadsEarlierPagesOnDemand",
            "PanelNeverExceedsItsHeightBudgetAndScrollsTheResultInstead",
        )
        for test_name in expected_tests:
            self.assertIn(test_name, source)

    def test_gate_requires_proxy_and_physical_120hz_for_non_pr_profiles(self):
        source = (PROJECT_ROOT / "scripts/e2e/run-gate.py").read_text(encoding="utf-8")
        self.assertIn('"performance-proxies"', source)
        self.assertIn('self.profile in ("nightly", "release") and self.physical_120hz_available', source)
        self.assertIn('report["frameClock"] == "view-bound-ca-display-link"', source)
        self.assertIn('(report["displayMaximumFramesPerSecond"] or 0) >= 120', source)

    def test_pr_certifies_proxies_without_claiming_physical_120hz(self):
        gate_module = load_gate_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            results = pathlib.Path(temporary_directory)
            gate = gate_module.GateRun("pr", results)
            gate.artifact_digest = "app-tree"
            gate.artifact_manifest = {"sourceCommit": gate.source_commit}
            gate.stages = [
                {"name": "performance-proxies", "status": "passed"},
                {"name": "release-artifact-final-verify", "status": "passed"},
            ]

            summary = gate.write_summary()

        self.assertTrue(summary["passed"])
        self.assertTrue(summary["performanceCertification"]["structuralProxyPassed"])
        self.assertFalse(summary["performanceCertification"]["physical120HzRequired"])
        self.assertIsNone(summary["performanceCertification"]["physical120HzPassed"])

    def test_release_cannot_pass_without_a_physical_120hz_report(self):
        gate_module = load_gate_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            results = pathlib.Path(temporary_directory)
            gate = gate_module.GateRun("release", results)
            gate.physical_120hz_available = True
            gate.artifact_digest = "app-tree"
            gate.artifact_manifest = {"sourceCommit": gate.source_commit}
            gate.stages = [
                {"name": "performance-proxies", "status": "passed"},
                {"name": "release-artifact-final-verify", "status": "passed"},
            ]

            summary = gate.write_summary()

        self.assertFalse(summary["passed"])
        self.assertTrue(summary["performanceCertification"]["physical120HzRequired"])
        self.assertFalse(summary["performanceCertification"]["physical120HzPassed"])

    def test_release_without_a_120hz_display_passes_and_records_the_skip(self):
        gate_module = load_gate_module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            results = pathlib.Path(temporary_directory)
            gate = gate_module.GateRun("release", results)
            gate.physical_120hz_available = False
            gate.artifact_digest = "app-tree"
            gate.artifact_manifest = {"sourceCommit": gate.source_commit}
            gate.stages = [
                {"name": "performance-environment-preflight", "status": "skipped"},
                {"name": "performance-proxies", "status": "passed"},
                {"name": "release-artifact-final-verify", "status": "passed"},
            ]

            summary = gate.write_summary()

        certification = summary["performanceCertification"]
        self.assertTrue(summary["passed"])
        self.assertFalse(certification["physical120HzRequired"])
        self.assertIsNone(certification["physical120HzPassed"])
        self.assertEqual(
            certification["physical120HzSkippedReason"], "no-awake-active-120hz-display"
        )

    def test_physical_workloads_run_only_on_a_120hz_display(self):
        source = (PROJECT_ROOT / "scripts/e2e/run-gate.py").read_text(encoding="utf-8")
        self.assertIn("and gate.physical_120hz_available\n        and not gate.run_performance()", source)


if __name__ == "__main__":
    unittest.main()
