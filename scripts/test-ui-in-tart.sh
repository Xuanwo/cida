#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
golden_vm=${CIDA_TART_GOLDEN_VM:-cida-ui-golden}
run_vm_prefix="cida-ui-run-$(date +%Y%m%d%H%M%S)-$$"
results_dir=${CIDA_TART_RESULTS_DIR:-"$project_dir/TestResults/vm-ui"}
only_testing=${CIDA_UI_TEST_ONLY_TESTING:-}
swift_test_sanitizer=${CIDA_TART_SWIFT_TEST_SANITIZER:-}
swift_test_filter=${CIDA_TART_SWIFT_TEST_FILTER:-}
guest_timeout_seconds=${CIDA_TART_GUEST_TIMEOUT_SECONDS:-600}
guest_session_timeout_seconds=${CIDA_TART_GUEST_SESSION_TIMEOUT_SECONDS:-900}
boot_attempts=${CIDA_TART_BOOT_ATTEMPTS:-2}

if (( $# != 0 )); then
  echo "Usage: $0" >&2
  exit 64
fi
if ! command -v tart >/dev/null 2>&1; then
  echo "OpenAI Tart is required: brew install openai/tools/tart" >&2
  exit 69
fi
if ! tart list | /usr/bin/grep -q "local  $golden_vm"; then
  echo "Tart golden VM is missing: $golden_vm" >&2
  exit 66
fi

mkdir -p "$results_dir"
project_dir=${project_dir:A}
results_dir=${results_dir:A}
artifact_root="$results_dir/ReleaseArtifact"
run_log="$results_dir/tart-run.log"
progress_log="$results_dir/vm-progress.log"
if [[ ! -d "$project_dir" || ! -d "$results_dir" ]]; then
  echo "Tart directory shares must resolve to existing directories" >&2
  exit 66
fi
: >"$progress_log"
host_progress() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $1" >>"$progress_log"
}

if [[ -e "$artifact_root" ]]; then
  if [[ "${CIDA_E2E_REUSE_ARTIFACT:-0}" != "1" ]]; then
    echo "Release artifact already exists; use a new result directory or set CIDA_E2E_REUSE_ARTIFACT=1" >&2
    exit 73
  fi
  host_progress "host-release-artifact-reuse-started"
  "$project_dir/scripts/e2e/verify-release-artifact.sh" \
    "$artifact_root" --require-developer-id >/dev/null
  host_progress "host-release-artifact-reuse-finished"
else
  host_progress "host-release-artifact-build-started"
  "$project_dir/scripts/e2e/build-release-artifact.sh" "$artifact_root" \
    >"$results_dir/release-artifact-build.log" 2>&1
  host_progress "host-release-artifact-build-finished"
fi

run_vm=""
run_pid=""
cleanup_current_vm() {
  if [[ -n "$run_pid" ]]; then
    tart stop "$run_vm" --timeout 30 >/dev/null 2>&1 || true
    wait "$run_pid" 2>/dev/null || true
    run_pid=""
  fi
  if [[ -n "$run_vm" ]]; then
    tart delete "$run_vm" >/dev/null 2>&1 || true
    run_vm=""
  fi
}
cleanup() { cleanup_current_vm }
trap cleanup EXIT INT TERM

probe_guest_agent() {
  /usr/bin/perl -e 'alarm shift @ARGV; exec @ARGV' \
    3 tart exec "$run_vm" /usr/bin/true >/dev/null 2>&1
}

probe_guest_session() {
  /usr/bin/perl -e 'alarm shift @ARGV; exec @ARGV' \
    5 tart exec "$run_vm" /bin/launchctl asuser 501 \
    /usr/bin/sudo -H -u admin /bin/zsh -lc '
      [[ "$(/usr/bin/id -u)" == "501" ]] \
        && /usr/bin/pgrep -x WindowServer >/dev/null \
        && /usr/bin/pgrep -x Dock >/dev/null \
        && /usr/bin/pgrep -x Finder >/dev/null \
        && /bin/launchctl kickstart gui/501/com.apple.testmanagerd >/dev/null 2>&1 \
        && /usr/bin/pgrep -x testmanagerd >/dev/null
    ' >/dev/null 2>&1
}

vm_ready=false
attempt=1
while (( attempt <= boot_attempts )); do
  run_vm="${run_vm_prefix}-${attempt}"
  host_progress "host-clone-started attempt=${attempt}"
  tart clone "$golden_vm" "$run_vm"
  # Keep the clone identity stable while giving concurrent test VMs distinct networking state.
  tart set "$run_vm" --random-mac
  host_progress "host-clone-finished attempt=${attempt}"

  : >"$run_log"
  tart run "$run_vm" \
    --no-graphics \
    --no-audio \
    --no-clipboard \
    --root-disk-opts="caching=cached,sync=none" \
    --dir="source:${project_dir}:ro" \
    --dir="artifacts:$results_dir" \
    >"$run_log" 2>&1 &
  run_pid=$!
  host_progress "host-vm-started attempt=${attempt}"

  guest_agent_ready=false
  guest_deadline=$((SECONDS + guest_timeout_seconds))
  while (( SECONDS < guest_deadline )); do
    if probe_guest_agent; then
      guest_agent_ready=true
      break
    fi
    if /usr/bin/grep -q '^Failed to run control socket:' "$run_log"; then
      host_progress "host-guest-agent-failed attempt=${attempt} reason=control-socket"
      break
    fi
    if ! kill -0 "$run_pid" 2>/dev/null; then
      host_progress "host-guest-agent-failed attempt=${attempt} reason=vm-stopped"
      break
    fi
    /bin/sleep 1
  done
  if [[ "$guest_agent_ready" != true ]]; then
    host_progress "host-guest-agent-failed attempt=${attempt} reason=timeout-or-startup"
    cleanup_current_vm
    attempt=$((attempt + 1))
    continue
  fi
  host_progress "host-guest-agent-ready attempt=${attempt}"

  if ! tart exec "$run_vm" /usr/bin/sudo /usr/sbin/networksetup \
    -setnetworkserviceenabled Ethernet off >/dev/null 2>&1
  then
    host_progress "host-guest-network-failed attempt=${attempt}"
    cleanup_current_vm
    attempt=$((attempt + 1))
    continue
  fi
  host_progress "host-guest-network-disabled attempt=${attempt}"

  guest_session_ready=false
  guest_session_deadline=$((SECONDS + guest_session_timeout_seconds))
  while (( SECONDS < guest_session_deadline )); do
    if probe_guest_session; then
      guest_session_ready=true
      break
    fi
    if ! kill -0 "$run_pid" 2>/dev/null; then
      host_progress "host-gui-session-failed attempt=${attempt} reason=vm-stopped"
      break
    fi
    /bin/sleep 1
  done
  if [[ "$guest_session_ready" == true ]]; then
    host_progress "host-gui-session-ready attempt=${attempt}"
    vm_ready=true
    break
  fi
  host_progress "host-gui-session-failed attempt=${attempt} reason=timeout-or-startup"
  cleanup_current_vm
  attempt=$((attempt + 1))
done
if [[ "$vm_ready" != true ]]; then
  echo "Tart infrastructure did not reach a ready macOS GUI session after $boot_attempts attempts" >&2
  exit 70
fi

tart exec "$run_vm" /bin/launchctl asuser 501 \
  /usr/bin/sudo -H -u admin /bin/zsh -lc '
  set -euo pipefail
  source_dir="/Volumes/My Shared Files/source"
  results_dir="/Volumes/My Shared Files/artifacts"
  work_dir="/Users/admin/cida-work"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) source-copy-started" >>"$results_dir/vm-progress.log"
  /bin/rm -rf "$work_dir"
  mkdir -p "$work_dir"
  /usr/bin/rsync -a \
    --exclude .git \
    --exclude .build \
    --exclude build \
    --exclude TestResults \
    "$source_dir/" "$work_dir/"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) source-copy-finished" >>"$results_dir/vm-progress.log"
'
tart exec "$run_vm" /bin/launchctl asuser 501 \
  /usr/bin/sudo -H -u admin /bin/zsh -lc '
  set -euo pipefail
  work_dir="/Users/admin/cida-work"
  results_dir="/Volumes/My Shared Files/artifacts"
  "$work_dir/scripts/run-vm-ui-tests-in-guest.sh" \
    "$work_dir" "$results_dir" "$1" "$2" "$3"
' -- "$only_testing" "$swift_test_sanitizer" "$swift_test_filter"

"$project_dir/scripts/e2e/verify-release-artifact.sh" \
  "$artifact_root" --require-developer-id >/dev/null
host_progress "host-release-artifact-reverified"

echo "$results_dir/CidaUITests.xcresult"
