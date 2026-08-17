#!/bin/zsh
set -euo pipefail

if (( $# < 1 )); then
  echo "Usage: $0 <Cida binary> [arguments...]" >&2
  exit 64
fi

script_dir=${0:A:h}
project_dir=${script_dir:h}
binary_path=$1
shift

if [[ ! -x "$binary_path" ]]; then
  echo "Cida automation binary is not executable: $binary_path" >&2
  exit 66
fi

binary_dir=${binary_path:h}
resource_bundle="$binary_dir/Cida_Cida.bundle"
if [[ ! -d "$resource_bundle" ]]; then
  app_resources="${binary_dir:h}/Resources/Cida_Cida.bundle"
  if [[ -d "$app_resources" ]]; then
    resource_bundle=$app_resources
  fi
fi
if [[ ! -d "$resource_bundle" ]]; then
  echo "Cida resource bundle is missing: $resource_bundle" >&2
  exit 66
fi

automation_root=$(mktemp -d "${TMPDIR:-/tmp}/cida-isolated-automation.XXXXXX")
trap '/bin/rm -r "$automation_root"' EXIT

app_path="$automation_root/Cida Automation.app"
bundle_identifier="com.xuanwo.Cida.Automation.run$$"

mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
/usr/bin/install -m 755 "$binary_path" "$app_path/Contents/MacOS/Cida"
/usr/bin/ditto "$resource_bundle" "$app_path/Contents/Resources/Cida_Cida.bundle"
/usr/bin/install -m 644 "$project_dir/Resources/Cida-Info.plist" \
  "$app_path/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleIdentifier -string "$bundle_identifier" \
  "$app_path/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleDisplayName -string "辞达测试" \
  "$app_path/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleName -string "辞达测试" \
  "$app_path/Contents/Info.plist"

actual_identifier=$(
  /usr/bin/plutil -extract CFBundleIdentifier raw "$app_path/Contents/Info.plist"
)
if [[ "$actual_identifier" != "$bundle_identifier" || "$actual_identifier" == "com.xuanwo.Cida" ]]; then
  echo "Automation bundle identity isolation failed" >&2
  exit 70
fi

/usr/bin/codesign --force --deep --sign - "$app_path"
/usr/bin/codesign --verify --deep --strict "$app_path"

if [[ -n "${CIDA_TIME_PROFILE_OUTPUT:-}" ]]; then
  automation_executable="${app_path:A}/Contents/MacOS/Cida"
  set +e
  /usr/bin/xcrun xctrace record \
    --quiet \
    --no-prompt \
    --template 'Time Profiler' \
    --output "$CIDA_TIME_PROFILE_OUTPUT" \
    --env CIDA_ISOLATED_AUTOMATION=1 \
    --launch -- "$app_path" "$@"
  trace_status=$?
  set -e

  # xctrace can leave its launched target suspended after the trace closes.
  # Reap only the process whose executable lives inside this unique temporary
  # automation bundle; never match a production Cida instance.
  for process_id in ${(@f)"$(/usr/bin/pgrep -f -- "$automation_executable" 2>/dev/null || true)"}; do
    command_line=$(/bin/ps -p "$process_id" -o command= 2>/dev/null || true)
    [[ "$command_line" == "$automation_executable"* ]] || continue
    /bin/kill -TERM "$process_id" 2>/dev/null || true
  done
  exit "$trace_status"
else
  CIDA_ISOLATED_AUTOMATION=1 "$app_path/Contents/MacOS/Cida" "$@"
fi
