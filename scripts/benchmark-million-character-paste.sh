#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
output_dir=${CIDA_PERFORMANCE_OUTPUT_DIR:-"$project_dir/Performance"}
output_dir=${output_dir:A}
report_path="$output_dir/million-character-paste-120hz.json"
last_report_path="$output_dir/million-character-paste-last-run.json"
sample_count=${1:-1440}

mkdir -p "$output_dir"
pending_path=$(mktemp "$output_dir/.million-character-paste.XXXXXX")
trap '/bin/rm -f "$pending_path"' EXIT

artifact_root=$("$script_dir/e2e/resolve-release-artifact.sh")

"$script_dir/run-isolated-automation.sh" "$artifact_root" \
  --performance-output "$pending_path" \
  --performance-workload million-character-paste \
  --performance-required-fps 120 \
  --performance-samples "$sample_count"

if [[ ! -s "$pending_path" ]]; then
  echo "Million-character paste gate did not produce a report" >&2
  exit 1
fi

cat "$pending_path"
/bin/cp "$pending_path" "$last_report_path"

passed=$(/usr/bin/plutil -extract passed raw "$pending_path")
display_satisfied=$(/usr/bin/plutil -extract displayRequirementSatisfied raw "$pending_path")
workload_completed=$(/usr/bin/plutil -extract workloadCompleted raw "$pending_path")
input_count=$(/usr/bin/plutil -extract inputCharacterCount raw "$pending_path")
missed_budgets=$(/usr/bin/plutil -extract missedFrameBudgetCount raw "$pending_path")

if [[ "$display_satisfied" != "true" ]]; then
  echo "Million-character paste gate requires a real 120 Hz display" >&2
  exit 1
fi

if [[ \
  "$passed" != "true" \
  || "$workload_completed" != "true" \
  || "$input_count" != "1000000" \
  || "$missed_budgets" != "0" \
]]; then
  echo "Million-character paste frame-pacing gate failed" >&2
  exit 1
fi

/bin/mv "$pending_path" "$report_path"
