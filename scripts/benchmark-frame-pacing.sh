#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
output_dir="$project_dir/Performance"
report_path="$output_dir/frame-pacing.json"
sample_count=${1:-720}

mkdir -p "$output_dir"
pending_path=$(mktemp "$output_dir/.frame-pacing.XXXXXX")
trap '/bin/rm -f "$pending_path"' EXIT
swift build \
  --package-path "$project_dir" \
  --configuration release \
  -Xswiftc -warnings-as-errors

binary_path=$(swift build \
  --package-path "$project_dir" \
  --configuration release \
  --show-bin-path)

"$script_dir/run-isolated-automation.sh" "$binary_path/Cida" \
  --performance-output "$pending_path" \
  --performance-samples "$sample_count"

cat "$pending_path"
passed=$(/usr/bin/plutil -extract passed raw "$pending_path")
if [[ "$passed" != "true" ]]; then
  echo "Frame pacing gate failed" >&2
  exit 1
fi

/bin/mv "$pending_path" "$report_path"
