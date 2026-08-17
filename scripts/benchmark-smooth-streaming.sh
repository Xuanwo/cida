#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
output_dir="$project_dir/Performance"
report_path="$output_dir/smooth-streaming-120hz.json"
last_report_path="$output_dir/smooth-streaming-last-run.json"
sample_count=${1:-1440}

mkdir -p "$output_dir"
pending_path=$(mktemp "$output_dir/.smooth-streaming.XXXXXX")
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
  --performance-workload streaming \
  --performance-required-fps 120 \
  --performance-zero-missed-frame-budgets \
  --performance-samples "$sample_count"

if [[ ! -s "$pending_path" ]]; then
  echo "Smooth-streaming gate did not produce a report" >&2
  exit 1
fi

cat "$pending_path"
/bin/cp "$pending_path" "$last_report_path"

passed=$(/usr/bin/plutil -extract passed raw "$pending_path")
display_satisfied=$(/usr/bin/plutil -extract displayRequirementSatisfied raw "$pending_path")
workload_completed=$(/usr/bin/plutil -extract workloadCompleted raw "$pending_path")
presentation_updates=$(/usr/bin/plutil -extract streamPresentationUpdateCount raw "$pending_path")
maximum_batch=$(
  /usr/bin/plutil -extract maximumStreamPresentationBatchCharacterCount raw "$pending_path"
)
missed_budgets=$(/usr/bin/plutil -extract missedFrameBudgetCount raw "$pending_path")

if [[ "$display_satisfied" != "true" ]]; then
  echo "Smooth-streaming gate requires a real 120 Hz display" >&2
  exit 1
fi

if [[ \
  "$passed" != "true" \
  || "$workload_completed" != "true" \
  || "$presentation_updates" -lt 12 \
  || "$maximum_batch" -gt 512 \
  || "$missed_budgets" != "0" \
]]; then
  echo "Smooth-streaming frame-pacing gate failed" >&2
  exit 1
fi

/bin/mv "$pending_path" "$report_path"
