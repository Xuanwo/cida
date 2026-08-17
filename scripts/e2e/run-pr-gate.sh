#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
exec /usr/bin/python3 "$script_dir/run-gate.py" pr "$@"
