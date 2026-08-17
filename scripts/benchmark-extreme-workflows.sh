#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
output_dir="$project_dir/Performance"
mode=${1:-smoke}
required_fps=${2:-120}
sample_count=${3:-2400}

case "$mode" in
  smoke)
    profiles=(smoke)
    ;;
  full)
    profiles=(million-history thousand-million-character-records)
    ;;
  million-history|thousand-million-character-records)
    profiles=($mode)
    ;;
  *)
    echo "Usage: $0 [smoke|full|million-history|thousand-million-character-records] [required-fps] [sample-count]" >&2
    exit 64
    ;;
esac

mkdir -p "$output_dir"

artifact_root=$("$script_dir/e2e/resolve-release-artifact.sh")

profile_arguments=()
for profile in "${profiles[@]}"; do
  profile_arguments+=(--profile "$profile")
done

/usr/bin/python3 "$script_dir/extreme-performance-matrix.py" \
  --artifact "$artifact_root" \
  --runner "$script_dir/run-isolated-automation.sh" \
  --output-directory "$output_dir" \
  --required-fps "$required_fps" \
  --sample-count "$sample_count" \
  "${profile_arguments[@]}"
