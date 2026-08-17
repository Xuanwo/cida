#!/usr/bin/env python3

import argparse
import datetime
import json
from pathlib import Path


def parse_arguments():
    parser = argparse.ArgumentParser(
        description="Prove a headless Cida test did not mutate the host app session."
    )
    parser.add_argument("before", type=Path)
    parser.add_argument("after", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--clipboard-isolated", action="store_true")
    parser.add_argument("--monitor-observations", required=True, type=Path)
    parser.add_argument("--monitor-healthy", action="store_true")
    return parser.parse_args()


def application_identity(application):
    if application is None:
        return None
    return {
        "bundleIdentifier": application.get("bundleIdentifier"),
        "executablePath": application.get("executablePath"),
        "processIdentifier": application.get("processIdentifier"),
    }


def read_observations(path):
    observations = []
    with path.open(encoding="utf-8") as source:
        for line_number, line in enumerate(source, 1):
            if not line.strip():
                continue
            try:
                observations.append(json.loads(line))
            except json.JSONDecodeError as error:
                raise RuntimeError(
                    f"invalid host monitor observation at line {line_number}: {error}"
                ) from error
    return observations


def parse_timestamp(snapshot):
    return datetime.datetime.fromisoformat(
        snapshot["capturedAt"].replace("Z", "+00:00")
    )


def main():
    arguments = parse_arguments()
    before = json.loads(arguments.before.read_text(encoding="utf-8"))
    after = json.loads(arguments.after.read_text(encoding="utf-8"))
    observations = read_observations(arguments.monitor_observations)
    before_cida = [application_identity(app) for app in before["productionCidaApplications"]]
    after_cida = [application_identity(app) for app in after["productionCidaApplications"]]
    before_frontmost = application_identity(before.get("frontmostApplication"))
    after_frontmost = application_identity(after.get("frontmostApplication"))
    observed_test_artifact_applications = {}
    for observation in observations:
        for application in observation.get("monitoredArtifactApplications", []):
            identity = application_identity(application)
            key = (
                identity.get("bundleIdentifier"),
                identity.get("executablePath"),
                identity.get("processIdentifier"),
            )
            observed_test_artifact_applications[key] = identity
    test_artifact_frontmost_observed = any(
        observation.get("frontmostApplicationMatchesMonitoredArtifact", False)
        for observation in observations
    )
    production_cida_processes_unchanged = before_cida == after_cida
    pasteboard_unchanged = (
        before["pasteboardChangeCount"] == after["pasteboardChangeCount"]
    )
    frontmost_application_changed = before_frontmost != after_frontmost
    observation_timestamps = [parse_timestamp(observation) for observation in observations]
    monitor_gaps = [
        (current - previous).total_seconds()
        for previous, current in zip(
            observation_timestamps, observation_timestamps[1:]
        )
    ]
    monitor_start_delay = (
        (observation_timestamps[0] - parse_timestamp(before)).total_seconds()
        if observation_timestamps
        else None
    )
    monitor_end_delay = (
        (parse_timestamp(after) - observation_timestamps[-1]).total_seconds()
        if observation_timestamps
        else None
    )
    monitor_maximum_gap = max(monitor_gaps) if monitor_gaps else None
    monitor_coverage_complete = (
        len(observations) >= 2
        and monitor_start_delay is not None
        and max(0, monitor_start_delay) <= 2
        and monitor_end_delay is not None
        and max(0, monitor_end_delay) <= 2
        and monitor_maximum_gap is not None
        and monitor_maximum_gap <= 2
    )
    report = {
        "schemaVersion": 1,
        "before": before,
        "after": after,
        "frontmostApplicationChanged": frontmost_application_changed,
        "testTargetFrontmostAtEnd": bool(
            observations
            and observations[-1].get(
                "frontmostApplicationMatchesMonitoredArtifact", False
            )
        ),
        "testArtifactFrontmostObserved": test_artifact_frontmost_observed,
        "testArtifactProcessObserved": bool(observed_test_artifact_applications),
        "observedTestArtifactApplications": list(
            observed_test_artifact_applications.values()
        ),
        "monitorHealthy": arguments.monitor_healthy,
        "monitorSampleCount": len(observations),
        "monitorCoverageComplete": monitor_coverage_complete,
        "monitorStartDelayMilliseconds": (
            round(max(0, monitor_start_delay) * 1000, 3)
            if monitor_start_delay is not None
            else None
        ),
        "monitorEndDelayMilliseconds": (
            round(max(0, monitor_end_delay) * 1000, 3)
            if monitor_end_delay is not None
            else None
        ),
        "monitorMaximumGapMilliseconds": (
            round(monitor_maximum_gap * 1000, 3)
            if monitor_maximum_gap is not None
            else None
        ),
        "pasteboardUnchanged": pasteboard_unchanged,
        "clipboardIsolationEnforced": arguments.clipboard_isolated,
        "productionCidaProcessesUnchanged": production_cida_processes_unchanged,
        "hostUserActivityObserved": (
            frontmost_application_changed
            or not pasteboard_unchanged
            or not production_cida_processes_unchanged
        ),
    }
    report["passed"] = (
        report["monitorHealthy"]
        and report["monitorCoverageComplete"]
        and not report["testArtifactFrontmostObserved"]
        and not report["testArtifactProcessObserved"]
        and (report["pasteboardUnchanged"] or report["clipboardIsolationEnforced"])
    )
    arguments.output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
