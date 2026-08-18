#!/usr/bin/env python3

import argparse
import json
import pathlib
import subprocess


SWIFT_INSPECTION_SOURCE = r"""
import AppKit
import CoreGraphics

_ = NSApplication.shared
for screen in NSScreen.screens {
  let key = NSDeviceDescriptionKey("NSScreenNumber")
  let displayID = (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
  let fields = [
    screen.localizedName,
    String(displayID),
    String(screen.maximumFramesPerSecond),
    CGDisplayIsOnline(displayID) != 0 ? "true" : "false",
    CGDisplayIsActive(displayID) != 0 ? "true" : "false",
    CGDisplayIsAsleep(displayID) != 0 ? "true" : "false",
  ]
  print(fields.joined(separator: "\t"))
}
"""


def parse_arguments():
    parser = argparse.ArgumentParser(
        description="Verify that an awake physical display can drive the performance gate."
    )
    parser.add_argument("--minimum-fps", type=int, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    return parser.parse_args()


def inspect_screens():
    process = subprocess.run(
        ["xcrun", "swift", "-e", SWIFT_INSPECTION_SOURCE],
        check=True,
        capture_output=True,
        text=True,
    )
    screens = []
    for line in process.stdout.splitlines():
        if not line.strip():
            continue
        name, display_id, maximum_fps, online, active, asleep = line.split("\t")
        screens.append(
            {
                "name": name,
                "displayID": int(display_id),
                "maximumFramesPerSecond": int(maximum_fps),
                "online": online == "true",
                "active": active == "true",
                "asleep": asleep == "true",
            }
        )
    return screens


def evaluate_screens(screens, minimum_fps):
    qualified = [
        screen
        for screen in screens
        if screen["online"]
        and screen["active"]
        and not screen["asleep"]
        and screen["maximumFramesPerSecond"] >= minimum_fps
    ]
    return {
        "schemaVersion": 1,
        "requiredFramesPerSecond": minimum_fps,
        "passed": bool(qualified),
        "failureCategory": None if qualified else "infrastructure",
        "reason": None if qualified else "no-awake-active-display-meets-frame-rate",
        "screens": screens,
        "qualifiedDisplayIDs": [screen["displayID"] for screen in qualified],
    }


def main():
    arguments = parse_arguments()
    try:
        screens = inspect_screens()
        report = evaluate_screens(screens, arguments.minimum_fps)
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        report = {
            "schemaVersion": 1,
            "requiredFramesPerSecond": arguments.minimum_fps,
            "passed": False,
            "failureCategory": "infrastructure",
            "reason": "display-inspection-failed",
            "error": str(error),
            "screens": [],
            "qualifiedDisplayIDs": [],
        }

    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    pending = arguments.output.with_suffix(arguments.output.suffix + ".pending")
    pending.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    pending.replace(arguments.output)
    print(json.dumps(report, sort_keys=True))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
