#!/usr/bin/env python3

import argparse
import datetime
import json
import os
import pathlib
import subprocess
import sys
import time


SCRIPT_PATH = pathlib.Path(__file__).resolve()
PROJECT_ROOT = SCRIPT_PATH.parents[2]
P0_RELEASE_TESTS = (
    "CidaUITests/CidaReleaseArtifactSmokeTests,"
    "CidaUITests/ComposerJourneyTests,"
    "CidaUITests/CoreTranslationJourneyTests,"
    "CidaUITests/HistoryAndScrollingJourneyTests,"
    "CidaUITests/PersistenceJourneyTests,"
    "CidaUITests/TranslationStateMachineJourneyTests,"
    "CidaUITests/WindowAndSettingsJourneyTests"
)


def parse_arguments():
    parser = argparse.ArgumentParser(
        description="Run a Cida PR, nightly, or release gate against one signed artifact."
    )
    parser.add_argument("profile", choices=("pr", "nightly", "release"))
    parser.add_argument("--results-dir", type=pathlib.Path)
    return parser.parse_args()


def run_output(command):
    return subprocess.check_output(command, cwd=PROJECT_ROOT, text=True).strip()


def read_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return None


class GateRun:
    def __init__(self, profile, results_directory):
        self.profile = profile
        self.results_directory = results_directory
        self.started_at = datetime.datetime.now(datetime.timezone.utc)
        self.source_commit = run_output(["git", "rev-parse", "HEAD"])
        self.source_dirty = bool(run_output(["git", "status", "--porcelain"]))
        self.stages = []
        self.artifact_root = self.results_directory / "ReleaseArtifact"
        self.artifact_digest = None
        self.artifact_manifest = None

    @property
    def summary_path(self):
        return self.results_directory / "gate-summary.json"

    def write_summary(self):
        ui_summaries = []
        for path in sorted(self.results_directory.glob("**/xcresult-summary.json")):
            payload = read_json(path)
            if payload is not None:
                ui_summaries.append(
                    {
                        "path": str(path.relative_to(self.results_directory)),
                        "result": payload.get("result"),
                        "totalTestCount": payload.get("totalTestCount"),
                        "passedTests": payload.get("passedTests"),
                        "failedTests": payload.get("failedTests"),
                    }
                )

        host_guards = []
        for path in sorted(self.results_directory.glob("**/host-session-guard.json")):
            payload = read_json(path)
            if payload is not None:
                host_guards.append(
                    {
                        "path": str(path.relative_to(self.results_directory)),
                        "passed": payload.get("passed"),
                        "frontmostApplicationChanged": payload.get(
                            "frontmostApplicationChanged"
                        ),
                        "hostUserActivityObserved": payload.get(
                            "hostUserActivityObserved"
                        ),
                        "pasteboardUnchanged": payload.get("pasteboardUnchanged"),
                        "clipboardIsolationEnforced": payload.get(
                            "clipboardIsolationEnforced"
                        ),
                        "productionCidaProcessesUnchanged": payload.get(
                            "productionCidaProcessesUnchanged"
                        ),
                        "monitorHealthy": payload.get("monitorHealthy"),
                        "monitorSampleCount": payload.get("monitorSampleCount"),
                        "monitorCoverageComplete": payload.get(
                            "monitorCoverageComplete"
                        ),
                        "monitorMaximumGapMilliseconds": payload.get(
                            "monitorMaximumGapMilliseconds"
                        ),
                        "testArtifactProcessObserved": payload.get(
                            "testArtifactProcessObserved"
                        ),
                        "testArtifactFrontmostObserved": payload.get(
                            "testArtifactFrontmostObserved"
                        ),
                    }
                )

        mutation_summaries = []
        for path in sorted(self.results_directory.glob("**/mutation-summary.json")):
            payload = read_json(path)
            if payload is not None:
                mutation_summaries.append(
                    {
                        "path": str(path.relative_to(self.results_directory)),
                        "mode": payload.get("mode"),
                        "mutationCount": payload.get("mutationCount"),
                        "killed": payload.get("killed"),
                        "survived": payload.get("survived"),
                        "infrastructureFailures": payload.get(
                            "infrastructureFailures"
                        ),
                    }
                )

        performance_reports = []
        for path in sorted((self.results_directory / "performance").glob("**/*.json")):
            payload = read_json(path)
            if payload is None:
                continue
            frame_payload = (
                payload
                if "frameClock" in payload
                else payload.get("frame_report")
            )
            if not isinstance(frame_payload, dict) or "frameClock" not in frame_payload:
                continue
            performance_reports.append(
                {
                    "path": str(path.relative_to(self.results_directory)),
                    "passed": frame_payload.get("passed"),
                    "workload": frame_payload.get("workload"),
                    "frameClock": frame_payload.get("frameClock"),
                    "artifactAppTreeSHA256": frame_payload.get("artifactAppTreeSHA256"),
                    "displayMaximumFramesPerSecond": frame_payload.get(
                        "displayMaximumFramesPerSecond"
                    ),
                    "measuredFramesPerSecond": frame_payload.get("measuredFramesPerSecond"),
                    "p99FrameTimeMilliseconds": frame_payload.get(
                        "p99FrameTimeMilliseconds"
                    ),
                    "missedFrameBudgetCount": frame_payload.get("missedFrameBudgetCount"),
                    "applicationActivationObserved": frame_payload.get(
                        "applicationActivationObserved"
                    ),
                    "probeWindowBecameKey": frame_payload.get("probeWindowBecameKey"),
                }
            )

        required_stages_passed = bool(self.stages) and all(
            stage["status"] == "passed" for stage in self.stages
        )
        final_verification_passed = any(
            stage["name"] == "release-artifact-final-verify"
            and stage["status"] == "passed"
            for stage in self.stages
        )
        performance_artifacts_match = all(
            report["artifactAppTreeSHA256"] == self.artifact_digest
            for report in performance_reports
        )
        finished_at = datetime.datetime.now(datetime.timezone.utc)
        summary = {
            "schemaVersion": 1,
            "profile": self.profile,
            "startedAt": self.started_at.isoformat(),
            "finishedAt": finished_at.isoformat(),
            "durationSeconds": round(
                (finished_at - self.started_at).total_seconds(), 3
            ),
            "source": {
                "commit": self.source_commit,
                "dirtyAtStart": self.source_dirty,
            },
            "artifact": {
                "root": str(self.artifact_root),
                "appTreeSHA256": self.artifact_digest,
                "manifest": self.artifact_manifest,
            },
            "stages": self.stages,
            "uiSummaries": ui_summaries,
            "hostSessionGuards": host_guards,
            "mutationSummaries": mutation_summaries,
            "performanceReports": performance_reports,
            "performanceArtifactsMatch": performance_artifacts_match,
            "passed": required_stages_passed
            and final_verification_passed
            and self.artifact_digest is not None
            and performance_artifacts_match,
        }
        temporary = self.summary_path.with_suffix(".json.pending")
        temporary.write_text(
            json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        temporary.replace(self.summary_path)
        return summary

    def record_preflight_failure(self, reason):
        self.stages.append(
            {
                "name": "preflight",
                "status": "failed",
                "exitCode": 1,
                "durationSeconds": 0,
                "reason": reason,
            }
        )
        self.write_summary()

    def run_stage(self, name, command, environment=None):
        log_path = self.results_directory / f"{name}.log"
        started = time.monotonic()
        with log_path.open("w", encoding="utf-8") as output:
            process = subprocess.run(
                command,
                cwd=PROJECT_ROOT,
                env=environment,
                stdout=output,
                stderr=subprocess.STDOUT,
                text=True,
                check=False,
            )
        stage = {
            "name": name,
            "status": "passed" if process.returncode == 0 else "failed",
            "exitCode": process.returncode,
            "durationSeconds": round(time.monotonic() - started, 3),
            "log": log_path.name,
        }
        self.stages.append(stage)
        self.write_summary()
        return process.returncode == 0

    def verify_artifact(self):
        command = [
            str(PROJECT_ROOT / "scripts/e2e/verify-release-artifact.sh"),
            str(self.artifact_root),
            "--require-clean-source",
            "--require-developer-id",
        ]
        digest = run_output(command)
        manifest = read_json(self.artifact_root / "artifact-manifest.json")
        if manifest is None:
            raise RuntimeError("artifact manifest is unreadable")
        if manifest.get("sourceCommit") != self.source_commit:
            raise RuntimeError("artifact source commit does not match the gate checkout")
        self.artifact_digest = digest
        self.artifact_manifest = manifest

    def build_artifact(self):
        if not self.run_stage(
            "release-artifact-build",
            [
                str(PROJECT_ROOT / "scripts/e2e/build-release-artifact.sh"),
                str(self.artifact_root),
            ],
        ):
            return False
        try:
            self.verify_artifact()
        except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
            self.stages.append(
                {
                    "name": "release-artifact-verify",
                    "status": "failed",
                    "exitCode": 1,
                    "durationSeconds": 0,
                    "reason": str(error),
                }
            )
            self.write_summary()
            return False
        self.stages.append(
            {
                "name": "release-artifact-verify",
                "status": "passed",
                "exitCode": 0,
                "durationSeconds": 0,
            }
        )
        self.write_summary()
        return True

    def run_tart(self, stage_name, output_name, selected_tests=None, boot_attempts=2):
        environment = os.environ.copy()
        environment.update(
            {
                "CIDA_RELEASE_ARTIFACT_ROOT": str(self.artifact_root),
                "CIDA_TART_RESULTS_DIR": str(self.results_directory / output_name),
                "CIDA_TART_SWIFT_TEST_FILTER": (
                    "AppModelTests/testNewModelStartsWithoutDesignHistory"
                ),
                "CIDA_TART_BOOT_ATTEMPTS": str(boot_attempts),
            }
        )
        if selected_tests:
            environment["CIDA_UI_TEST_ONLY_TESTING"] = selected_tests
        return self.run_stage(
            stage_name,
            [str(PROJECT_ROOT / "scripts/test-ui-in-tart.sh")],
            environment,
        )

    def run_mutations(self):
        mode = "unit" if self.profile == "pr" else "all"
        return self.run_stage(
            f"mutation-{mode}",
            [
                str(PROJECT_ROOT / "scripts/e2e/run-mutation-contracts.sh"),
                "--mode",
                mode,
                "--results-dir",
                str(self.results_directory / "mutations"),
            ],
        )

    def run_performance(self):
        performance_directory = self.results_directory / "performance"
        environment = os.environ.copy()
        environment.update(
            {
                "CIDA_RELEASE_ARTIFACT_ROOT": str(self.artifact_root),
                "CIDA_PERFORMANCE_OUTPUT_DIR": str(performance_directory),
            }
        )
        stages = [
            ("performance-streaming", ["scripts/benchmark-smooth-streaming.sh"]),
            ("performance-million-paste", ["scripts/benchmark-million-character-paste.sh"]),
            ("performance-history-scroll", ["scripts/benchmark-large-history-scroll.sh"]),
        ]
        if self.profile == "nightly":
            stages.append(
                ("performance-extreme-smoke", ["scripts/benchmark-extreme-workflows.sh", "smoke"])
            )
        elif self.profile == "release":
            stages.append(
                ("performance-extreme-full", ["scripts/benchmark-extreme-workflows.sh", "full"])
            )
        passed = True
        for name, command in stages:
            passed = self.run_stage(
                name,
                [str(PROJECT_ROOT / command[0]), *command[1:]],
                environment,
            ) and passed
        return passed


def main():
    arguments = parse_arguments()
    timestamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    results_directory = (
        arguments.results_dir
        or PROJECT_ROOT / "TestResults" / "gates" / f"{arguments.profile}-{timestamp}"
    ).resolve()
    if results_directory.exists():
        print(f"Gate result directory already exists: {results_directory}", file=sys.stderr)
        return 2
    results_directory.mkdir(parents=True)
    gate = GateRun(arguments.profile, results_directory)

    if gate.source_dirty:
        gate.record_preflight_failure("gate execution requires a clean source checkout")
        print(gate.summary_path)
        return 1

    if not gate.run_stage(
        "swift-tests",
        ["swift", "test", "-Xswiftc", "-warnings-as-errors"],
    ):
        print(gate.summary_path)
        return 1
    if not gate.build_artifact():
        print(gate.summary_path)
        return 1

    selected_tests = P0_RELEASE_TESTS if gate.profile == "pr" else None
    if not gate.run_tart("tart-correctness", "correctness", selected_tests):
        print(gate.summary_path)
        return 1
    if not gate.run_mutations():
        print(gate.summary_path)
        return 1

    if gate.profile == "release":
        burn_in_rounds = max(2, int(os.environ.get("CIDA_GATE_BURN_IN_ROUNDS", "3")))
        for round_index in range(1, burn_in_rounds + 1):
            if not gate.run_tart(
                f"tart-p0-burn-in-{round_index}",
                f"burn-in-{round_index}",
                P0_RELEASE_TESTS,
                boot_attempts=1,
            ):
                print(gate.summary_path)
                return 1

    if gate.profile in ("nightly", "release") and not gate.run_performance():
        print(gate.summary_path)
        return 1

    if not gate.run_stage(
        "release-artifact-final-verify",
        [
            str(PROJECT_ROOT / "scripts/e2e/verify-release-artifact.sh"),
            str(gate.artifact_root),
            "--require-clean-source",
            "--require-developer-id",
        ],
    ):
        print(gate.summary_path)
        return 1
    gate.verify_artifact()
    summary = gate.write_summary()
    print(gate.summary_path)
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError, ValueError) as error:
        print(f"Gate runner infrastructure failure: {error}", file=sys.stderr)
        raise SystemExit(2)
