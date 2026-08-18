import pathlib
import subprocess
import tempfile
import unittest


PROJECT_ROOT = pathlib.Path(__file__).resolve().parents[3]
DIAGNOSTIC_RUNNER = PROJECT_ROOT / "scripts/e2e/run-focused-tart-diagnostic.sh"
TART_RUNNER = PROJECT_ROOT / "scripts/test-ui-in-tart.sh"
GUEST_RUNNER = PROJECT_ROOT / "scripts/run-vm-ui-tests-in-guest.sh"
VM_EXISTS = PROJECT_ROOT / "scripts/e2e/tart-vm-exists.sh"


class DiagnosticContractTests(unittest.TestCase):
    def test_invalid_selector_fails_before_build_or_vm_work(self):
        result = subprocess.run(
            [str(DIAGNOSTIC_RUNNER), "not-a-cida-test"],
            cwd=PROJECT_ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 64)
        self.assertIn("must begin with CidaUITests/", result.stderr)

    def test_skip_is_explicit_and_cannot_run_an_unfiltered_ui_suite(self):
        host_source = TART_RUNNER.read_text(encoding="utf-8")
        guest_source = GUEST_RUNNER.read_text(encoding="utf-8")

        self.assertIn('diagnostic_mode=${CIDA_TART_DIAGNOSTIC_MODE:-0}', host_source)
        self.assertIn('Diagnostic mode requires CIDA_UI_TEST_ONLY_TESTING', host_source)
        self.assertIn('progress "swift-test-skipped diagnostic-mode=true"', guest_source)
        self.assertIn('if [[ "$diagnostic_mode" == 1 ]]', guest_source)

    def test_vm_lookup_consumes_all_tart_output_without_pipefail_sigpipe(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            fake_tart = pathlib.Path(temporary_directory) / "tart"
            fake_tart.write_text(
                "#!/bin/sh\n"
                "[ \"$1\" = list ] || exit 64\n"
                "echo 'Source Name Disk Size'\n"
                "echo 'local  cida-ui-golden 140 86 stopped'\n"
                "i=0\n"
                "while [ $i -lt 10000 ]; do echo \"local  trailing-$i 1 1 stopped\"; i=$((i + 1)); done\n",
                encoding="utf-8",
            )
            fake_tart.chmod(0o755)
            environment = {"PATH": f"{temporary_directory}:/usr/bin:/bin"}

            found = subprocess.run(
                [str(VM_EXISTS), "cida-ui-golden"], env=environment, check=False
            )
            missing = subprocess.run(
                [str(VM_EXISTS), "missing-vm"], env=environment, check=False
            )

        self.assertEqual(found.returncode, 0)
        self.assertEqual(missing.returncode, 1)


if __name__ == "__main__":
    unittest.main()
