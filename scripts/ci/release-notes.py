#!/usr/bin/env python3
"""Prints the hand-written update notes of a Cida version (Design/spec/lifecycle.md §六).

docs/releases/<version>.md holds one item per line, each starting with "- "; blank lines are
allowed. The items are printed one per line without the "- ", as update-appcast.py takes
them. A missing file, a line that is not an item, or a file without items fails, so a
release never ships without notes. A release candidate uses the notes of the version it
will become.

    release-notes.py 1.1.0 [--directory docs/releases]
"""

import argparse
import pathlib
import sys

PROJECT_ROOT = pathlib.Path(__file__).resolve().parents[2]
ITEM_MARKER = "- "


def parse_arguments(arguments):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("version", help="X.Y.Z, without a -rc.N suffix")
    parser.add_argument("--directory", type=pathlib.Path, default=PROJECT_ROOT / "docs/releases")
    return parser.parse_args(arguments)


def read_notes(path):
    if not path.is_file():
        raise SystemExit(f"{path} is missing; write the update notes for this version first")
    items = []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if not line.strip():
            continue
        item = line[len(ITEM_MARKER):].strip() if line.startswith(ITEM_MARKER) else ""
        if not item:
            raise SystemExit(f"{path}:{number}: every line must be one item starting with \"- \"")
        items.append(item)
    if not items:
        raise SystemExit(f"{path} has no items")
    return items


def main(arguments):
    arguments = parse_arguments(arguments)
    items = read_notes(arguments.directory / f"{arguments.version}.md")
    sys.stdout.write("".join(f"{item}\n" for item in items))


if __name__ == "__main__":
    main(sys.argv[1:])
