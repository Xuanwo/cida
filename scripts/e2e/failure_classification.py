#!/usr/bin/env python3

import argparse
import datetime
import json
import pathlib


VALID_CATEGORIES = {
    "artifact",
    "build",
    "infrastructure",
    "source-test",
    "ui-assertion-or-crash",
}


def write_classification(path, category, phase, exit_code, detail):
    if category not in VALID_CATEGORIES:
        raise ValueError(f"unsupported failure category: {category}")
    payload = {
        "schemaVersion": 1,
        "category": category,
        "phase": phase,
        "exitCode": exit_code,
        "detail": detail,
        "recordedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    pending = path.with_suffix(path.suffix + ".pending")
    pending.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    pending.replace(path)
    return payload


def parse_arguments():
    parser = argparse.ArgumentParser(description="Write one Cida test failure classification.")
    parser.add_argument("path", type=pathlib.Path)
    parser.add_argument("category", choices=sorted(VALID_CATEGORIES))
    parser.add_argument("phase")
    parser.add_argument("exit_code", type=int)
    parser.add_argument("detail")
    return parser.parse_args()


def main():
    arguments = parse_arguments()
    write_classification(
        arguments.path,
        arguments.category,
        arguments.phase,
        arguments.exit_code,
        arguments.detail,
    )


if __name__ == "__main__":
    main()
