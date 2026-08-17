#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
output_dir="$project_dir/TestResults"
report_path="$output_dir/release-input-interaction.json"

if (( $# > 1 )); then
  echo "Usage: $0 [Cida release binary]" >&2
  exit 64
fi

mkdir -p "$output_dir"
pending_path=$(mktemp "$output_dir/.release-input-interaction.XXXXXX")
trap '/bin/rm -f "$pending_path"' EXIT

if (( $# == 1 )); then
  binary_path=$1
else
  swift build \
    --package-path "$project_dir" \
    --configuration release \
    -Xswiftc -warnings-as-errors

  release_bin_dir=$(swift build \
    --package-path "$project_dir" \
    --configuration release \
    --show-bin-path)
  binary_path="$release_bin_dir/Cida"
fi

"$script_dir/run-isolated-automation.sh" "$binary_path" \
  --input-interaction-output "$pending_path"

if [[ ! -s "$pending_path" ]]; then
  echo "Release input interaction test did not produce a report" >&2
  exit 1
fi

cat "$pending_path"
passed=$(/usr/bin/plutil -extract passed raw "$pending_path")
application_activated=$(
  /usr/bin/plutil -extract applicationActivationObserved raw "$pending_path"
)
window_became_key=$(/usr/bin/plutil -extract probeWindowBecameKey raw "$pending_path")

if [[ \
  "$passed" != "true" \
  || "$application_activated" != "false" \
  || "$window_became_key" != "false" \
]]; then
  echo "Release input interaction test failed" >&2
  exit 1
fi

/bin/mv "$pending_path" "$report_path"
