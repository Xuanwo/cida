#!/usr/bin/env python3

import argparse
import json
import pathlib


def parse_arguments():
    parser = argparse.ArgumentParser(
        description="Merge independently sampled host-session observation streams."
    )
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("inputs", nargs="+", type=pathlib.Path)
    return parser.parse_args()


def main():
    arguments = parse_arguments()
    observations = []
    for path in arguments.inputs:
        with path.open(encoding="utf-8") as source:
            for line_number, line in enumerate(source, 1):
                if not line.strip():
                    continue
                try:
                    observations.append(json.loads(line))
                except json.JSONDecodeError as error:
                    raise RuntimeError(
                        f"{path}:{line_number}: invalid observation: {error}"
                    ) from error
    observations.sort(key=lambda observation: observation["capturedAt"])
    with arguments.output.open("w", encoding="utf-8") as output:
        for observation in observations:
            output.write(json.dumps(observation, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
