#!/usr/bin/env python3

import argparse
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
    return parser.parse_args()


def application_identity(application):
    if application is None:
        return None
    return {
        "bundleIdentifier": application.get("bundleIdentifier"),
        "executablePath": application.get("executablePath"),
        "processIdentifier": application.get("processIdentifier"),
    }


def main():
    arguments = parse_arguments()
    before = json.loads(arguments.before.read_text(encoding="utf-8"))
    after = json.loads(arguments.after.read_text(encoding="utf-8"))
    before_cida = [application_identity(app) for app in before["productionCidaApplications"]]
    after_cida = [application_identity(app) for app in after["productionCidaApplications"]]
    after_frontmost = application_identity(after.get("frontmostApplication"))
    target_frontmost = bool(
        after_frontmost
        and (after_frontmost.get("bundleIdentifier") or "").startswith("com.xuanwo.Cida")
    )
    report = {
        "schemaVersion": 1,
        "before": before,
        "after": after,
        "frontmostApplicationChanged": application_identity(
            before.get("frontmostApplication")
        )
        != after_frontmost,
        "testTargetFrontmostAtEnd": target_frontmost,
        "pasteboardUnchanged": before["pasteboardChangeCount"]
        == after["pasteboardChangeCount"],
        "clipboardIsolationEnforced": arguments.clipboard_isolated,
        "productionCidaProcessesUnchanged": before_cida == after_cida,
    }
    report["passed"] = (
        not report["testTargetFrontmostAtEnd"]
        and (report["pasteboardUnchanged"] or report["clipboardIsolationEnforced"])
        and report["productionCidaProcessesUnchanged"]
    )
    arguments.output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
