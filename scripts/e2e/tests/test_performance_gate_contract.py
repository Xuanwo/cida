import importlib.util
import pathlib
import tempfile
import unittest


PROJECT_ROOT = pathlib.Path(__file__).resolve().parents[3]
GATE_MODULE_PATH = PROJECT_ROOT / "scripts/e2e/run-gate.py"


def load_gate_module():
    spec = importlib.util.spec_from_file_location("cida_run_gate", GATE_MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class PerformanceGateContractTests(unittest.TestCase):
    def test_pr_proxy_names_every_bounded_rendering_invariant(self):
        source = (PROJECT_ROOT / "scripts/e2e/run-performance-proxies.sh").read_text(
            encoding="utf-8"
        )
        expected_tests = (
            "ScrollingUpThroughLargeFoldedHistoryDoesNotReadCompleteResults",
            "FoldedHistoryMaterializesOnlyTheViewportPoolDuringHyperScroll",
            "LongResultUsesIncrementalNaturalTextLayoutWithoutNestedScrolling",
            "HighFrequencyResultUpdatesCoalesceNaturalHeightLayout",
            "ComposerVirtualizesLargeDocumentAndLoadsEarlierPagesOnDemand",
        )
        for test_name in expected_tests:
            self.assertIn(test_name, source)

    def test_gate_requires_proxy_and_physical_120hz_for_non_pr_profiles(self):
        source = (PROJECT_ROOT / "scripts/e2e/run-gate.py").read_text(encoding="utf-8")
        self.assertIn('"performance-proxies"', source)
        self.assertIn('physical_120hz_required = self.profile in ("nightly", "release")', source)
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


if __name__ == "__main__":
    unittest.main()
