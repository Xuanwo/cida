#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
output_dir="$project_dir/Performance"
report_path="$output_dir/large-history-scroll-120hz.json"
last_report_path="$output_dir/large-history-scroll-last-run.json"
sample_count=${1:-1440}

mkdir -p "$output_dir"
pending_path=$(mktemp "$output_dir/.large-history-scroll.XXXXXX")
trap '/bin/rm -f "$pending_path"' EXIT

artifact_root=$("$script_dir/e2e/resolve-release-artifact.sh")

"$script_dir/run-isolated-automation.sh" "$artifact_root" \
  --performance-output "$pending_path" \
  --performance-workload large-history-scroll \
  --performance-required-fps 120 \
  --performance-zero-missed-frame-budgets \
  --performance-samples "$sample_count"

if [[ ! -s "$pending_path" ]]; then
  echo "Large-history scroll gate did not produce a report" >&2
  exit 1
fi

cat "$pending_path"
/bin/cp "$pending_path" "$last_report_path"

passed=$(/usr/bin/plutil -extract passed raw "$pending_path")
display_satisfied=$(/usr/bin/plutil -extract displayRequirementSatisfied raw "$pending_path")
workload_completed=$(/usr/bin/plutil -extract workloadCompleted raw "$pending_path")
history_count=$(/usr/bin/plutil -extract historyEntryCount raw "$pending_path")
scroll_distance=$(/usr/bin/plutil -extract scrollDistancePoints raw "$pending_path")
missed_budgets=$(/usr/bin/plutil -extract missedFrameBudgetCount raw "$pending_path")

if [[ "$display_satisfied" != "true" ]]; then
  echo "Large-history scroll gate requires a real 120 Hz display" >&2
  exit 1
fi

if [[ \
  "$passed" != "true" \
  || "$workload_completed" != "true" \
  || "$history_count" != "1000" \
  || "$scroll_distance" -lt "12000" \
  || "$missed_budgets" != "0" \
]]; then
  echo "Large-history scroll frame-pacing gate failed" >&2
  exit 1
fi

/bin/mv "$pending_path" "$report_path"
