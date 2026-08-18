#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h:h}

if (( $# < 1 || $# > 2 )); then
  echo "Usage: $0 <CidaUITests/test-selector> [swift-test-filter]" >&2
  exit 64
fi

ui_test_selector=$1
swift_test_filter=${2:-}
if [[ "$ui_test_selector" != CidaUITests/* ]]; then
  echo "The selector must begin with CidaUITests/" >&2
  exit 64
fi

timestamp=$(date +%Y%m%d-%H%M%S)
results_dir=${CIDA_TART_RESULTS_DIR:-"$project_dir/TestResults/diagnostics/$timestamp"}

cd "$project_dir"
swift build -Xswiftc -warnings-as-errors
if [[ -n "$swift_test_filter" ]]; then
  swift test --skip-build -Xswiftc -warnings-as-errors --filter "$swift_test_filter"
fi

echo "Focused Tart diagnostics are not a release verdict; run a formal gate before delivery."
CIDA_TART_DIAGNOSTIC_MODE=1 \
  CIDA_UI_TEST_ONLY_TESTING="$ui_test_selector" \
  CIDA_TART_RESULTS_DIR="$results_dir" \
  exec "$project_dir/scripts/test-ui-in-tart.sh"
