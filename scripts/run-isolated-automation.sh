#!/bin/zsh
set -euo pipefail

if (( $# < 1 )); then
  echo "Usage: $0 <Release artifact directory|Cida binary> [arguments...]" >&2
  exit 64
fi

script_dir=${0:A:h}
project_dir=${script_dir:h}
automation_target=${1:A}
shift

artifact_digest=""
artifact_source_commit=""
if [[ -d "$automation_target" && -f "$automation_target/artifact-manifest.json" ]]; then
  artifact_root=$automation_target
  artifact_digest=$(
    "$project_dir/scripts/e2e/verify-release-artifact.sh" "$artifact_root"
  )
  app_relative_path=$(
    /usr/bin/plutil -extract appRelativePath raw "$artifact_root/artifact-manifest.json"
  )
  app_path="$artifact_root/$app_relative_path"
  binary_path="$app_path/Contents/MacOS/Cida"
  artifact_source_commit=$(
    /usr/bin/plutil -extract sourceCommit raw "$artifact_root/artifact-manifest.json"
  )
else
  binary_path=$automation_target
  if [[ ! -x "$binary_path" ]]; then
    echo "Cida automation target is neither a Release artifact nor an executable: $automation_target" >&2
    exit 66
  fi

  automation_root=$(mktemp -d "${TMPDIR:-/tmp}/cida-isolated-automation.XXXXXX")
  trap '/bin/rm -r "$automation_root"' EXIT

  app_path="$automation_root/Cida Automation.app"
  bundle_identifier="com.xuanwo.Cida.Automation.run$$"

  "$script_dir/assemble-app.sh" "$binary_path" "$app_path"
  /usr/bin/plutil -replace CFBundleIdentifier -string "$bundle_identifier" \
    "$app_path/Contents/Info.plist"
  /usr/bin/plutil -replace CFBundleDisplayName -string "辞达测试" \
    "$app_path/Contents/Info.plist"
  /usr/bin/plutil -replace CFBundleName -string "辞达测试" \
    "$app_path/Contents/Info.plist"
  # The localized name (辞达) would hide the test name from the system.
  /bin/rm -rf "$app_path"/Contents/Resources/*.lproj(N)

  actual_identifier=$(
    /usr/bin/plutil -extract CFBundleIdentifier raw "$app_path/Contents/Info.plist"
  )
  if [[ "$actual_identifier" != "$bundle_identifier" || "$actual_identifier" == "com.xuanwo.Cida" ]]; then
    echo "Automation bundle identity isolation failed" >&2
    exit 70
  fi

  "$script_dir/sign-app.sh" "$app_path" -
fi

power_source=$(
  /usr/bin/pmset -g batt \
    | /usr/bin/sed -n "s/^Now drawing from '\(.*\)'$/\1/p" \
    | /usr/bin/head -1
)
automation_environment=(
  CIDA_ISOLATED_AUTOMATION=1
  "CIDA_ARTIFACT_APP_TREE_SHA256=$artifact_digest"
  "CIDA_ARTIFACT_SOURCE_COMMIT=$artifact_source_commit"
  "CIDA_PERFORMANCE_POWER_SOURCE=${power_source:-unknown}"
)

if [[ -n "${CIDA_TIME_PROFILE_OUTPUT:-}" ]]; then
  automation_executable="${app_path:A}/Contents/MacOS/Cida"
  /usr/bin/env "${automation_environment[@]}" "$automation_executable" "$@" &
  target_pid=$!
  set +e
  /usr/bin/xcrun xctrace record \
    --quiet \
    --no-prompt \
    --template 'Time Profiler' \
    --output "$CIDA_TIME_PROFILE_OUTPUT" \
    --attach "$target_pid"
  trace_status=$?
  if (( trace_status != 0 )); then
    /bin/kill -TERM "$target_pid" 2>/dev/null || true
  fi
  wait "$target_pid"
  target_status=$?
  set -e

  # xctrace can leave its launched target suspended after the trace closes.
  # Reap only the process whose executable lives inside this unique temporary
  # automation bundle; never match a production Cida instance.
  for process_id in ${(@f)"$(/usr/bin/pgrep -f -- "$automation_executable" 2>/dev/null || true)"}; do
    command_line=$(/bin/ps -p "$process_id" -o command= 2>/dev/null || true)
    [[ "$command_line" == "$automation_executable"* ]] || continue
    /bin/kill -TERM "$process_id" 2>/dev/null || true
  done
  (( target_status == 0 )) || exit "$target_status"
  exit "$trace_status"
else
  /usr/bin/env "${automation_environment[@]}" "$app_path/Contents/MacOS/Cida" "$@"
fi
