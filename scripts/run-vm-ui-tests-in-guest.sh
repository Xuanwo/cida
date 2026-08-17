#!/bin/zsh
set -euo pipefail

if (( $# < 2 || $# > 5 )); then
  echo "Usage: $0 <guest source directory> <guest results directory> [only-testing] [swift-test-sanitizer] [swift-test-filter]" >&2
  exit 64
fi

project_dir=${1:A}
results_dir=${2:A}
work_root="${project_dir:h}/cida-ui-test-work"
shared_artifact_root="$results_dir/ReleaseArtifact"
artifact_root="$work_root/ReleaseArtifact"
app_path="$artifact_root/Cida.app"
derived_data="$work_root/DerivedData"
record_path="$results_dir/openai-request.json"
port_path="$work_root/mock-port"
server_log="$results_dir/mock-server.log"
xcresult_path="$results_dir/CidaUITests.xcresult"
xcresult_summary_path="$results_dir/xcresult-summary.json"
progress_path="$results_dir/vm-progress.log"
only_testing=${3:-}
swift_test_sanitizer=${4:-}
swift_test_filter=${5:-}
typeset -a test_selection
test_selection=()
if [[ -n "$only_testing" ]]; then
  for selected_test in ${(s:,:)only_testing}; do
    [[ -n "$selected_test" ]] && test_selection+=(-only-testing:"$selected_test")
  done
fi
typeset -a swift_test_arguments
swift_test_arguments=(-Xswiftc -warnings-as-errors)
if [[ -n "$swift_test_sanitizer" ]]; then
  swift_test_arguments+=(--sanitize "$swift_test_sanitizer")
fi
if [[ -n "$swift_test_filter" ]]; then
  swift_test_arguments+=(--filter "$swift_test_filter")
fi

progress() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $1" >>"$progress_path"
}

print_failure_log() {
  local log_path=$1
  echo "Command failed; last 200 log lines from $log_path" >&2
  /usr/bin/tail -200 "$log_path" >&2
}

collect_diagnostics() {
  local diagnostic_results_dir="$results_dir/DiagnosticReports"
  mkdir -p "$diagnostic_results_dir"
  /usr/bin/find \
    "$HOME/Library/Logs/DiagnosticReports" \
    "/Library/Logs/DiagnosticReports" \
    -maxdepth 1 \
    -type f \
    -name '*.ips' \
    -mmin -10 \
    -exec /bin/cp {} "$diagnostic_results_dir/" \; \
    2>/dev/null || true
}

if /usr/bin/nc -G 2 -z 1.1.1.1 443 >/dev/null 2>&1; then
  echo "Guest network isolation is not active: public egress is reachable" >&2
  exit 69
fi

mkdir -p "$results_dir"
/bin/rm -rf "$work_root"
mkdir -p "$work_root"
/usr/bin/ditto "$shared_artifact_root" "$artifact_root"

artifact_digest=$(
  "$project_dir/scripts/e2e/verify-release-artifact.sh" \
    "$artifact_root" --require-developer-id
)
progress "release-artifact-verified digest=$artifact_digest"

cd "$project_dir"
progress "swift-test-started"
swift_test_log="$results_dir/swift-test.log"
: >"$swift_test_log"
swift_test_failed=false
if [[ -n "$swift_test_filter" ]]; then
  if ! SWIFT_BACKTRACE=enable swift test "${swift_test_arguments[@]}" \
    >>"$swift_test_log" 2>&1
  then
    swift_test_failed=true
  fi
else
  if ! SWIFT_BACKTRACE=enable swift test "${swift_test_arguments[@]}" \
    --skip InteractionReproductionTests >>"$swift_test_log" 2>&1
  then
    swift_test_failed=true
  fi
  interaction_filters=(
    'InteractionReproductionTests/test[A-H]' \
    'InteractionReproductionTests/test[I-P]' \
    'InteractionReproductionTests/test(Record|Recycled|Scrolling|Settings|Staged)' \
    'InteractionReproductionTests/testStreaming' \
    'InteractionReproductionTests/test(Submit|Virtual|Window)'
  )
  interaction_filter_union="${(j:|:)interaction_filters}"
  uncovered_interaction_tests=$(
    swift test list --skip-build \
      | /usr/bin/awk -v pattern="$interaction_filter_union" '
          /^CidaTests\.InteractionReproductionTests\// && $0 !~ pattern { print }
        '
  )
  if [[ -n "$uncovered_interaction_tests" ]]; then
    {
      echo "Interaction test sharding does not cover:"
      echo "$uncovered_interaction_tests"
    } >>"$swift_test_log"
    swift_test_failed=true
  fi
  for interaction_filter in "${interaction_filters[@]}"; do
    if [[ "$swift_test_failed" == false ]] \
      && ! SWIFT_BACKTRACE=enable swift test "${swift_test_arguments[@]}" \
        --skip-build --filter "$interaction_filter" >>"$swift_test_log" 2>&1
    then
      swift_test_failed=true
    fi
  done
fi
if [[ "$swift_test_failed" == true ]]; then
  /bin/sleep 2
  collect_diagnostics
  print_failure_log "$swift_test_log"
  exit 1
fi
progress "swift-test-passed"

/usr/bin/python3 "$project_dir/UITests/Fixtures/e2e_scenario_server.py" \
  "$record_path" "$port_path" >"$server_log" 2>&1 &
server_pid=$!
trap '/bin/kill "$server_pid" 2>/dev/null || true' EXIT

for attempt in {1..100}; do
  [[ -s "$port_path" ]] && break
  /bin/sleep 0.05
done
if [[ ! -s "$port_path" ]]; then
  echo "Local OpenAI mock did not start" >&2
  exit 70
fi
progress "local-openai-mock-ready"

export CIDA_UI_TEST_APP_PATH="$app_path"
export CIDA_UI_TEST_ENDPOINT="http://127.0.0.1:$(<"$port_path")/v1/chat/completions"
export CIDA_UI_TEST_RECORD_PATH="$record_path"
export CIDA_UI_TEST_WORK_ROOT="$work_root"
export CIDA_UI_TEST_SOURCE_ROOT="$project_dir"

/bin/rm -rf "$xcresult_path"
/bin/rm -f "$xcresult_summary_path"
progress "xcui-build-for-testing-started"
if ! xcodebuild build-for-testing \
  -project "$project_dir/UITests/CidaUITests.xcodeproj" \
  -scheme CidaUITests \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived_data" \
  -parallel-testing-enabled NO \
  CODE_SIGN_IDENTITY=- \
  >"$results_dir/xcodebuild-ui-build.log" 2>&1
then
  collect_diagnostics
  print_failure_log "$results_dir/xcodebuild-ui-build.log"
  exit 1
fi
progress "xcui-build-for-testing-passed"

# Xcode installation can post a one-time extension banner over the app's titlebar.
# Build first, then reset transient desktop UI before exercising real hit targets.
/usr/bin/sqlite3 \
  "$HOME/Library/Group Containers/group.com.apple.usernoted/db2/db" \
  "begin immediate;
   delete from record where app_id in (
     select app_id from app where identifier = 'com.apple.btmnotificationagent'
   );
   delete from delivered where app_id in (
     select app_id from app where identifier = 'com.apple.btmnotificationagent'
   );
   delete from displayed where app_id in (
     select app_id from app where identifier = 'com.apple.btmnotificationagent'
   );
   commit;" >/dev/null
/usr/bin/killall NotificationCenter >/dev/null 2>&1 || true
/usr/bin/killall "System Settings" >/dev/null 2>&1 || true
/usr/bin/killall Terminal >/dev/null 2>&1 || true
/bin/sleep 1

/bin/launchctl kickstart -k "gui/$(/usr/bin/id -u)/com.apple.testmanagerd" >/dev/null
for attempt in {1..50}; do
  /usr/bin/pgrep -x testmanagerd >/dev/null && break
  /bin/sleep 0.1
done
if ! /usr/bin/pgrep -x testmanagerd >/dev/null; then
  echo "macOS testmanagerd did not become ready" >&2
  exit 70
fi

progress "xcui-test-started"
if ! xcodebuild test-without-building \
  -project "$project_dir/UITests/CidaUITests.xcodeproj" \
  -scheme CidaUITests \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$xcresult_path" \
  -parallel-testing-enabled NO \
  "${test_selection[@]}" \
  CODE_SIGN_IDENTITY=- \
  >"$results_dir/xcodebuild-ui-tests.log" 2>&1
then
  /bin/sleep 2
  collect_diagnostics
  print_failure_log "$results_dir/xcodebuild-ui-tests.log"
  exit 1
fi
progress "xcui-test-passed"

if ! xcrun xcresulttool get test-results summary \
  --path "$xcresult_path" \
  --format json >"$xcresult_summary_path"
then
  echo "XCUI result summary generation failed" >&2
  exit 1
fi
progress "xcui-summary-generated"

verified_digest=$(
  "$project_dir/scripts/e2e/verify-release-artifact.sh" \
    "$artifact_root" --require-developer-id
)
if [[ "$verified_digest" != "$artifact_digest" ]]; then
  echo "Release artifact changed while XCUI was running" >&2
  exit 1
fi
progress "release-artifact-reverified digest=$verified_digest"

shared_digest=$(
  "$project_dir/scripts/e2e/verify-release-artifact.sh" \
    "$shared_artifact_root" --require-developer-id
)
if [[ "$shared_digest" != "$artifact_digest" ]]; then
  echo "Shared release artifact changed while XCUI was running" >&2
  exit 1
fi
progress "shared-release-artifact-reverified digest=$shared_digest"
