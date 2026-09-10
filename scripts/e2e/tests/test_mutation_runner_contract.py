import importlib.util
import pathlib
import tempfile
import unittest


MODULE_PATH = pathlib.Path(__file__).parents[1] / "run-mutation-contracts.py"
SPEC = importlib.util.spec_from_file_location("cida_run_mutation_contracts", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class MutationRunnerContractTests(unittest.TestCase):
    def write_log(self, directory, text):
        path = pathlib.Path(directory) / "unit-test-1.log"
        path.write_text(text, encoding="utf-8")
        return path

    def test_a_filter_that_matches_no_test_case_is_missing_not_survived(self):
        with tempfile.TemporaryDirectory() as directory:
            log = self.write_log(
                directory,
                "warning: No matching test cases were run\n"
                "Test Suite 'Selected tests' passed at 2026-09-10 16:44:25.758.\n"
                "\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds\n",
            )
            self.assertEqual(MODULE.unit_test_outcome(0, log), "Missing")

    def test_an_assertion_failure_kills_and_a_green_run_survives(self):
        with tempfile.TemporaryDirectory() as directory:
            failed = self.write_log(
                directory,
                "Test Case '-[CidaTests.InteractionReproductionTests testFade]' started.\n"
                "error: XCTAssertEqual failed\n"
                "Test Case '-[CidaTests.InteractionReproductionTests testFade]' failed (0.1 seconds).\n",
            )
            self.assertEqual(MODULE.unit_test_outcome(1, failed), "Failed")
            passed = self.write_log(
                directory,
                "Test Case '-[CidaTests.InteractionReproductionTests testFade]' started.\n"
                "Test Case '-[CidaTests.InteractionReproductionTests testFade]' passed (0.1 seconds).\n",
            )
            self.assertEqual(MODULE.unit_test_outcome(0, passed), "PassedOrInvalid")

    def test_catalog_kill_tests_must_be_declared_in_the_test_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            tests = pathlib.Path(directory) / "Tests"
            tests.mkdir()
            (tests / "Sample.swift").write_text(
                "extension InteractionReproductionTests {\n"
                "  func testRowFades() throws {}\n"
                "}\n",
                encoding="utf-8",
            )
            declared = MODULE.declared_test_methods(tests)
            self.assertEqual(declared, {"testRowFades"})
            mutation = {
                "unitTests": ["InteractionReproductionTests/testRowFades"],
                "releaseTests": ["HistoryPresentationJourneyTests/testRenamedJourney"],
            }
            self.assertEqual(
                MODULE.missing_kill_tests(mutation, declared, {"testFoldedResultAlwaysFades"}),
                ["HistoryPresentationJourneyTests/testRenamedJourney"],
            )

    def test_checked_in_catalog_names_only_declared_kill_tests(self):
        catalog = MODULE.json.loads(MODULE.CATALOG_PATH.read_text(encoding="utf-8"))
        unit_methods = MODULE.declared_test_methods(MODULE.PROJECT_ROOT / "Tests")
        release_methods = MODULE.declared_test_methods(MODULE.PROJECT_ROOT / "UITests")
        for mutation in catalog["mutations"]:
            self.assertEqual(
                MODULE.missing_kill_tests(mutation, unit_methods, release_methods),
                [],
                mutation["id"],
            )


if __name__ == "__main__":
    unittest.main()
