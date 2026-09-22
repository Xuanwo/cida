#!/usr/bin/env python3

import argparse
import datetime
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time


SCRIPT_PATH = pathlib.Path(__file__).resolve()
PROJECT_ROOT = SCRIPT_PATH.parents[2]
CATALOG_PATH = SCRIPT_PATH.with_name("mutation-catalog.json")


def parse_arguments():
    parser = argparse.ArgumentParser(
        description="Inject Cida regressions into temporary clones and require designated tests to fail."
    )
    parser.add_argument(
        "--mode",
        choices=("catalog", "unit", "release", "all"),
        default="unit",
        help="Validation depth. Release and all execute XCUI inside headless Tart clones.",
    )
    parser.add_argument(
        "--mutation",
        action="append",
        default=[],
        help="Run only the named mutation. May be repeated.",
    )
    parser.add_argument(
        "--results-dir",
        type=pathlib.Path,
        help="New directory for logs and mutation-summary.json.",
    )
    return parser.parse_args()


def run(command, *, cwd, log_path, environment=None):
    started = time.monotonic()
    with log_path.open("w", encoding="utf-8") as output:
        process = subprocess.run(
            command,
            cwd=cwd,
            env=environment,
            stdout=output,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
    return process.returncode, time.monotonic() - started


def output(command, *, cwd):
    return subprocess.check_output(command, cwd=cwd, text=True).strip()


def sha256(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def apply_mutation(clone, mutation):
    source_path = clone / mutation["file"]
    source = source_path.read_text(encoding="utf-8")
    before = mutation["before"]
    expected_occurrences = mutation["occurrences"]
    actual_occurrences = source.count(before)
    if actual_occurrences != expected_occurrences:
        raise RuntimeError(
            f"{mutation['id']}: expected {expected_occurrences} replacement anchor, "
            f"found {actual_occurrences} in {mutation['file']}"
        )
    mutated = source.replace(before, mutation["after"], expected_occurrences)
    source_path.write_text(mutated, encoding="utf-8")
    return {
        "file": mutation["file"],
        "beforeSHA256": sha256(source),
        "afterSHA256": sha256(mutated),
    }


def unit_test_outcome(return_code, log_path):
    """Classify one targeted `swift test --filter` run.

    A filter that matches no test case exits 0 and prints no `Test Case` lines;
    that must never count as a survived or killed mutation, because the kill
    contract simply did not execute.
    """
    text = log_path.read_text(encoding="utf-8", errors="replace")
    if "Test Case '" not in text:
        return "Missing"
    if return_code != 0 and "' failed (" in text:
        return "Failed"
    return "PassedOrInvalid"


TEST_METHOD_PATTERN = re.compile(r"^\s*func\s+(test\w+)\s*\(", re.MULTILINE)


def declared_test_methods(directory):
    methods = set()
    for path in sorted(directory.rglob("*.swift")):
        methods.update(TEST_METHOD_PATTERN.findall(path.read_text(encoding="utf-8")))
    return methods


def missing_kill_tests(mutation, unit_methods, release_methods):
    missing = []
    for key, methods in (("unitTests", unit_methods), ("releaseTests", release_methods)):
        for test_name in mutation[key]:
            method = test_name.rsplit("/", 1)[-1]
            if method not in methods:
                missing.append(test_name)
    return missing


def run_unit_contracts(clone, mutation, result_directory):
    build_log = result_directory / "unit-build.log"
    return_code, duration = run(
        [
            "swift",
            "build",
            "--package-path",
            str(clone),
            "--build-tests",
            "-Xswiftc",
            "-warnings-as-errors",
        ],
        cwd=clone,
        log_path=build_log,
    )
    result = {
        "buildExitCode": return_code,
        "buildDurationSeconds": round(duration, 3),
        "tests": [],
    }
    if return_code != 0:
        result["status"] = "infrastructure"
        result["reason"] = "mutated source did not compile"
        return result

    for index, test_name in enumerate(mutation["unitTests"]):
        test_log = result_directory / f"unit-test-{index + 1}.log"
        return_code, duration = run(
            [
                "swift",
                "test",
                "--package-path",
                str(clone),
                "--skip-build",
                "--filter",
                test_name,
            ],
            cwd=clone,
            log_path=test_log,
        )
        result["tests"].append(
            {
                "name": test_name,
                "exitCode": return_code,
                "durationSeconds": round(duration, 3),
                "result": unit_test_outcome(return_code, test_log),
                "log": test_log.name,
            }
        )
    outcomes = [test["result"] for test in result["tests"]]
    if "Missing" in outcomes:
        result["status"] = "infrastructure"
        result["reason"] = "one or more unit kill tests did not execute"
    elif all(outcome == "Failed" for outcome in outcomes):
        result["status"] = "killed"
    else:
        result["status"] = "survived"
    return result


def flatten_test_nodes(nodes):
    flattened = {}
    for node in nodes:
        identifier = node.get("nodeIdentifier")
        if node.get("nodeType") == "Test Case" and identifier:
            flattened[identifier.removesuffix("()")] = node.get("result")
        flattened.update(flatten_test_nodes(node.get("children", [])))
    return flattened


def run_release_contracts(clone, mutation, result_directory):
    tart_results = result_directory / "tart"
    runner_log = result_directory / "release-runner.log"
    environment = os.environ.copy()
    environment.update(
        {
            "CIDA_TART_RESULTS_DIR": str(tart_results),
            "CIDA_UI_TEST_ONLY_TESTING": ",".join(
                f"CidaUITests/{name}" for name in mutation["releaseTests"]
            ),
            "CIDA_TART_SWIFT_TEST_FILTER": (
                "AppModelTests/testNewModelStartsWithoutAResult"
            ),
            "CIDA_TART_BOOT_ATTEMPTS": "1",
        }
    )
    return_code, duration = run(
        [str(clone / "scripts/test-ui-in-tart.sh")],
        cwd=clone,
        log_path=runner_log,
        environment=environment,
    )
    result = {
        "runnerExitCode": return_code,
        "durationSeconds": round(duration, 3),
        "tests": [],
        "runnerLog": runner_log.name,
    }
    xcresult = tart_results / "CidaUITests.xcresult"
    if not xcresult.exists():
        result["status"] = "infrastructure"
        result["reason"] = "targeted Tart run did not produce an xcresult"
        return result

    nodes_path = result_directory / "release-test-nodes.json"
    nodes_return_code, _ = run(
        [
            "xcrun",
            "xcresulttool",
            "get",
            "test-results",
            "tests",
            "--path",
            str(xcresult),
            "--format",
            "json",
        ],
        cwd=clone,
        log_path=nodes_path,
    )
    if nodes_return_code != 0:
        result["status"] = "infrastructure"
        result["reason"] = "xcresult test nodes could not be decoded"
        return result

    nodes = json.loads(nodes_path.read_text(encoding="utf-8"))
    observed = flatten_test_nodes(nodes.get("testNodes", []))
    all_failed = True
    for test_name in mutation["releaseTests"]:
        observed_result = observed.get(test_name)
        result["tests"].append({"name": test_name, "result": observed_result or "Missing"})
        all_failed = all_failed and observed_result == "Failed"

    if all_failed and return_code != 0:
        result["status"] = "killed"
    elif return_code == 0:
        result["status"] = "survived"
        result["reason"] = "targeted Release journey stayed green"
    elif any(test["result"] == "Missing" for test in result["tests"]):
        result["status"] = "infrastructure"
        result["reason"] = "one or more targeted Release journeys did not execute"
    else:
        result["status"] = "survived"
        result["reason"] = "one or more targeted Release journeys did not reject the mutation"
    return result


def validate_catalog(catalog, selected_ids):
    if catalog.get("schemaVersion") != 1:
        raise RuntimeError("unsupported mutation catalog schema")
    mutations = catalog.get("mutations", [])
    ids = [mutation["id"] for mutation in mutations]
    if len(ids) != len(set(ids)):
        raise RuntimeError("mutation identifiers must be unique")
    unknown = sorted(set(selected_ids) - set(ids))
    if unknown:
        raise RuntimeError(f"unknown mutations: {', '.join(unknown)}")
    unit_methods = declared_test_methods(PROJECT_ROOT / "Tests")
    release_methods = declared_test_methods(PROJECT_ROOT / "UITests")
    for mutation in mutations:
        if not mutation["unitTests"] or not mutation["releaseTests"]:
            raise RuntimeError(f"{mutation['id']}: unit and Release kill tests are required")
        missing = missing_kill_tests(mutation, unit_methods, release_methods)
        if missing:
            raise RuntimeError(
                f"{mutation['id']}: catalog drift, kill tests are not declared: {', '.join(missing)}"
            )
        source = (PROJECT_ROOT / mutation["file"]).read_text(encoding="utf-8")
        actual = source.count(mutation["before"])
        if actual != mutation["occurrences"]:
            raise RuntimeError(
                f"{mutation['id']}: catalog drift, expected {mutation['occurrences']} anchors, found {actual}"
            )
    return [mutation for mutation in mutations if not selected_ids or mutation["id"] in selected_ids]


def main():
    arguments = parse_arguments()
    catalog = json.loads(CATALOG_PATH.read_text(encoding="utf-8"))
    mutations = validate_catalog(catalog, arguments.mutation)
    if arguments.mode == "catalog":
        print(f"Validated {len(mutations)} mutation definitions.")
        return 0

    if output(["git", "status", "--porcelain"], cwd=PROJECT_ROOT):
        raise RuntimeError("mutation execution requires a clean source checkout")
    source_commit = output(["git", "rev-parse", "HEAD"], cwd=PROJECT_ROOT)
    timestamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    results_root = arguments.results_dir or (
        PROJECT_ROOT / "TestResults" / f"mutations-{arguments.mode}-{timestamp}"
    )
    results_root = results_root.resolve()
    if results_root.exists():
        raise RuntimeError(f"results directory already exists: {results_root}")
    results_root.mkdir(parents=True)

    records = []
    with tempfile.TemporaryDirectory(prefix="cida-mutations-") as temporary:
        temporary_root = pathlib.Path(temporary)
        for mutation in mutations:
            print(f"[{mutation['id']}] cloning and applying mutation", flush=True)
            clone = temporary_root / mutation["id"]
            subprocess.run(
                [
                    "git",
                    "clone",
                    "--quiet",
                    "--local",
                    "--no-hardlinks",
                    str(PROJECT_ROOT),
                    str(clone),
                ],
                check=True,
            )
            result_directory = results_root / mutation["id"]
            result_directory.mkdir()
            record = {
                "id": mutation["id"],
                "description": mutation["description"],
                "contracts": mutation["contracts"],
                "patch": apply_mutation(clone, mutation),
            }
            if arguments.mode in ("unit", "all"):
                print(f"[{mutation['id']}] running unit kill contracts", flush=True)
                record["unit"] = run_unit_contracts(clone, mutation, result_directory)
            if arguments.mode in ("release", "all"):
                print(f"[{mutation['id']}] running headless Tart Release kill contracts", flush=True)
                record["release"] = run_release_contracts(clone, mutation, result_directory)

            statuses = [
                value["status"]
                for key, value in record.items()
                if key in ("unit", "release")
            ]
            if any(status == "infrastructure" for status in statuses):
                record["status"] = "infrastructure"
            elif all(status == "killed" for status in statuses):
                record["status"] = "killed"
            else:
                record["status"] = "survived"
            print(f"[{mutation['id']}] {record['status']}", flush=True)
            records.append(record)

    summary = {
        "schemaVersion": 1,
        "sourceCommit": source_commit,
        "mode": arguments.mode,
        "mutationCount": len(records),
        "killed": sum(record["status"] == "killed" for record in records),
        "survived": sum(record["status"] == "survived" for record in records),
        "infrastructureFailures": sum(
            record["status"] == "infrastructure" for record in records
        ),
        "mutations": records,
    }
    summary_path = results_root / "mutation-summary.json"
    summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(summary_path)
    return 0 if summary["survived"] == 0 and summary["infrastructureFailures"] == 0 else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"mutation runner infrastructure failure: {error}", file=sys.stderr)
        raise SystemExit(2)
